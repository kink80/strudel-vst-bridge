// auv3_host.m — Minimal AUv3 plugin host with GUI support for macOS.
// Hosts AudioUnit plugins via the modern AUAudioUnit API so that
// the same instance handles both audio rendering and GUI display.

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudioKit/CoreAudioKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMIDI/CoreMIDI.h>
#import <AppKit/AppKit.h>
#include <stdint.h>
#include <string.h>

// ─── Types ──────────────────────────────────────────────────────────────────

typedef struct {
    void* auAudioUnit;       // AUAudioUnit* (retained) — for params, state, MIDI scheduling
    void* avAudioUnit;       // AVAudioUnit* (retained) — engine-attachable node
    MIDIEndpointRef midiEndpoint;  // virtual MIDI destination (0 if none)
    uint32_t maxFrames;
    double sampleRate;
    void* guiWindow;         // NSWindow* (retained)
    void* guiViewController; // NSViewController* (retained)
    char name[256];
    char manufacturer[256];
    char label[128];         // user-facing instance label (for MIDI port name)
} AUv3Plugin;

// ─── Shared engine + CoreMIDI client ────────────────────────────────────────
static AVAudioEngine* g_engine = nil;
static MIDIClientRef  g_midiClient = 0;

static void ensureEngine(double sampleRate) {
    (void)sampleRate; // engine derives format from the default output device
    if (g_engine) return;
    g_engine = [[AVAudioEngine alloc] init];
    NSLog(@"[auv3] AVAudioEngine created");
}

static void ensureMIDIClient(void) {
    if (g_midiClient) return;
    OSStatus s = MIDIClientCreate((__bridge CFStringRef)@"strudel-vst-bridge", NULL, NULL, &g_midiClient);
    if (s != noErr) {
        NSLog(@"[auv3] MIDIClientCreate failed: %d", (int)s);
        g_midiClient = 0;
        return;
    }
    NSLog(@"[auv3] CoreMIDI client created");
}

// Forward declarations — definitions below.
int  auv3_engine_attach(AUv3Plugin* plugin);
void auv3_engine_detach(AUv3Plugin* plugin);
int  auv3_create_midi_source(AUv3Plugin* plugin, const char* label);
void auv3_destroy_midi_source(AUv3Plugin* plugin);

// ─── Plugin lifecycle ───────────────────────────────────────────────────────

// Synchronous wrapper around async AUAudioUnit instantiation
AUv3Plugin* auv3_load_plugin(const char* componentName, double sampleRate, uint32_t maxFrames) {
    __block AUv3Plugin* result = NULL;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    // Find the component by name
    AudioComponentDescription searchDesc = {
        .componentType = kAudioUnitType_MusicDevice, // Instruments
        .componentSubType = 0,
        .componentManufacturer = 0,
        .componentFlags = 0,
        .componentFlagsMask = 0,
    };

    NSString* targetName = [NSString stringWithUTF8String:componentName];
    NSString* targetLower = [targetName lowercaseString];

    AudioComponent comp = NULL;
    AudioComponent found = NULL;
    while ((comp = AudioComponentFindNext(comp, &searchDesc)) != NULL) {
        CFStringRef cfName = NULL;
        AudioComponentCopyName(comp, &cfName);
        if (cfName) {
            NSString* name = (__bridge_transfer NSString*)cfName;
            if ([[name lowercaseString] containsString:targetLower]) {
                found = comp;
                break;
            }
        }
    }

    if (!found) {
        NSLog(@"[auv3] Plugin not found: %s", componentName);
        return NULL;
    }

    AudioComponentDescription desc;
    AudioComponentGetDescription(found, &desc);

    // Dispatch instantiation to main thread — JUCE's AUv3 wrapper initializes
    // its MessageManager during instantiation, which must happen on the main thread
    // for popup menus and modal dialogs to work correctly.
    dispatch_async(dispatch_get_main_queue(), ^{
    [AVAudioUnit instantiateWithComponentDescription:desc
                                             options:kAudioComponentInstantiation_LoadInProcess
                                   completionHandler:^(AVAudioUnit* _Nullable avAudioUnit, NSError* _Nullable error) {
        if (error || !avAudioUnit) {
            NSLog(@"[auv3] Failed to instantiate: %@", error);
            dispatch_semaphore_signal(sem);
            return;
        }

        AUAudioUnit* auAudioUnit = avAudioUnit.AUAudioUnit;
        auAudioUnit.maximumFramesToRender = maxFrames;
        // Engine handles allocateRenderResources at attach/start time.

        AUv3Plugin* plugin = (AUv3Plugin*)calloc(1, sizeof(AUv3Plugin));
        plugin->auAudioUnit = (__bridge_retained void*)auAudioUnit;
        plugin->avAudioUnit = (__bridge_retained void*)avAudioUnit;
        plugin->midiEndpoint = 0;
        plugin->maxFrames = maxFrames;
        plugin->sampleRate = sampleRate;
        plugin->guiWindow = NULL;
        plugin->guiViewController = NULL;
        plugin->label[0] = '\0';

        // Copy name
        NSString* fullName = auAudioUnit.audioUnitName ?: @"Unknown";
        NSString* mfr = auAudioUnit.manufacturerName ?: @"Unknown";
        strncpy(plugin->name, [fullName UTF8String], 255);
        strncpy(plugin->manufacturer, [mfr UTF8String], 255);

        NSLog(@"[auv3] Loaded: %@ by %@ (%u params)",
              fullName, mfr, (uint32_t)auAudioUnit.parameterTree.allParameters.count);

        result = plugin;
        dispatch_semaphore_signal(sem);
    }];
    }); // end dispatch_async to main queue

    // Wait up to 10 seconds
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return result;
}

void auv3_destroy_plugin(AUv3Plugin* plugin) {
    if (!plugin) return;

    // Detach + tear down MIDI first so no events can land on a dying node.
    auv3_engine_detach(plugin);
    auv3_destroy_midi_source(plugin);

    if (plugin->guiWindow) {
        NSWindow* win = (__bridge_transfer NSWindow*)plugin->guiWindow;
        dispatch_async(dispatch_get_main_queue(), ^{
            [win close];
        });
    }
    if (plugin->guiViewController) {
        NSViewController* vc __attribute__((unused)) = (__bridge_transfer NSViewController*)plugin->guiViewController;
    }

    AUAudioUnit* au __attribute__((unused)) = (__bridge_transfer AUAudioUnit*)plugin->auAudioUnit;
    AVAudioUnit* avau __attribute__((unused)) = (__bridge_transfer AVAudioUnit*)plugin->avAudioUnit;

    free(plugin);
}

// ─── Engine attach / detach ─────────────────────────────────────────────────

int auv3_engine_attach(AUv3Plugin* plugin) {
    if (!plugin || !plugin->avAudioUnit) return -1;
    ensureEngine(plugin->sampleRate);

    AVAudioUnit* avau = (__bridge AVAudioUnit*)plugin->avAudioUnit;
    AVAudioFormat* fmt = [g_engine.mainMixerNode outputFormatForBus:0];

    [g_engine attachNode:avau];
    [g_engine connect:avau to:g_engine.mainMixerNode format:fmt];

    if (!g_engine.isRunning) {
        NSError* err = nil;
        if (![g_engine startAndReturnError:&err]) {
            NSLog(@"[auv3] engine start failed: %@", err);
            return -2;
        }
        NSLog(@"[auv3] engine started, sr=%.0f", fmt.sampleRate);
    }
    NSLog(@"[auv3] attached '%s' to engine", plugin->name);
    return 0;
}

void auv3_engine_detach(AUv3Plugin* plugin) {
    if (!plugin || !plugin->avAudioUnit || !g_engine) return;
    AVAudioUnit* avau = (__bridge AVAudioUnit*)plugin->avAudioUnit;
    @try {
        [g_engine disconnectNodeOutput:avau];
        [g_engine detachNode:avau];
    } @catch (NSException* ex) {
        NSLog(@"[auv3] detach threw: %@", ex);
    }
}

// ─── Per-instance virtual MIDI destination ──────────────────────────────────

// MIDI read callback. Runs on a high-priority CoreMIDI thread.
// Forwards bytes to the AU's scheduleMIDIEventBlock (realtime-safe).
static void instanceMidiReadProc(const MIDIPacketList* pktList, void* refCon, void* srcConnRefCon) {
    (void)srcConnRefCon;
    AUv3Plugin* plugin = (AUv3Plugin*)refCon;
    if (!plugin || !plugin->auAudioUnit) return;
    AUAudioUnit* au = (__bridge AUAudioUnit*)plugin->auAudioUnit;
    AUScheduleMIDIEventBlock midiBlock = au.scheduleMIDIEventBlock;
    if (!midiBlock) return;

    const MIDIPacket* pkt = &pktList->packet[0];
    for (UInt32 i = 0; i < pktList->numPackets; i++) {
        if (pkt->length > 0 && pkt->length <= 3) {
            midiBlock(AUEventSampleTimeImmediate, 0, pkt->length, pkt->data);
        }
        pkt = MIDIPacketNext(pkt);
    }
}

int auv3_create_midi_source(AUv3Plugin* plugin, const char* label) {
    if (!plugin) return -1;
    ensureMIDIClient();
    if (!g_midiClient) return -2;

    strncpy(plugin->label, label ?: "", sizeof(plugin->label) - 1);
    plugin->label[sizeof(plugin->label) - 1] = '\0';

    NSString* portName = [NSString stringWithFormat:@"strudel-vst:%s", plugin->label];
    MIDIEndpointRef endpoint = 0;
    OSStatus s = MIDIDestinationCreate(g_midiClient, (__bridge CFStringRef)portName,
                                       instanceMidiReadProc, plugin, &endpoint);
    if (s != noErr) {
        NSLog(@"[auv3] MIDIDestinationCreate(%@) failed: %d", portName, (int)s);
        return -3;
    }
    plugin->midiEndpoint = endpoint;
    NSLog(@"[auv3] virtual MIDI destination: %@", portName);
    return 0;
}

void auv3_destroy_midi_source(AUv3Plugin* plugin) {
    if (!plugin || plugin->midiEndpoint == 0) return;
    MIDIEndpointDispose(plugin->midiEndpoint);
    plugin->midiEndpoint = 0;
}

// ─── MIDI ───────────────────────────────────────────────────────────────────

int auv3_send_midi(AUv3Plugin* plugin, const uint8_t* data, uint32_t length) {
    if (!plugin || !plugin->auAudioUnit) return -1;
    AUAudioUnit* au = (__bridge AUAudioUnit*)plugin->auAudioUnit;

    AUScheduleMIDIEventBlock midiBlock = au.scheduleMIDIEventBlock;
    if (midiBlock) {
        midiBlock(AUEventSampleTimeImmediate, 0, length, data);
        return 0;
    }
    return -1;
}

int auv3_note_on(AUv3Plugin* plugin, uint8_t note, uint8_t velocity, uint8_t channel) {
    uint8_t data[3] = { (uint8_t)(0x90 | (channel & 0x0F)), note & 0x7F, velocity & 0x7F };
    return auv3_send_midi(plugin, data, 3);
}

int auv3_note_off(AUv3Plugin* plugin, uint8_t note, uint8_t velocity, uint8_t channel) {
    uint8_t data[3] = { (uint8_t)(0x80 | (channel & 0x0F)), note & 0x7F, velocity & 0x7F };
    return auv3_send_midi(plugin, data, 3);
}

// ─── GUI ────────────────────────────────────────────────────────────────────

void auv3_show_gui(AUv3Plugin* plugin) {
    if (!plugin || !plugin->auAudioUnit) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // If window already exists, just bring it to front
        if (plugin->guiWindow) {
            NSWindow* window = (__bridge NSWindow*)plugin->guiWindow;
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            NSLog(@"[auv3] Brought existing GUI window to front for: %s", plugin->name);
            return;
        }

        AUAudioUnit* au = (__bridge AUAudioUnit*)plugin->auAudioUnit;

        [au requestViewControllerWithCompletionHandler:^(AUViewControllerBase* _Nullable vc) {
            if (!vc) {
                NSLog(@"[auv3] No view controller available for GUI");
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                NSView* view = vc.view;
                NSSize viewSize = view.frame.size;
                if (viewSize.width < 1 || viewSize.height < 1) {
                    viewSize = NSMakeSize(800, 600);
                }

                NSLog(@"[auv3] Creating GUI window: %@ (%gx%g)",
                      NSStringFromClass([view class]), viewSize.width, viewSize.height);

                NSRect frame = NSMakeRect(100, 100, viewSize.width, viewSize.height);
                NSWindow* window = [[NSWindow alloc]
                    initWithContentRect:frame
                              styleMask:(NSWindowStyleMaskTitled |
                                        NSWindowStyleMaskClosable |
                                        NSWindowStyleMaskMiniaturizable |
                                        NSWindowStyleMaskResizable)
                                backing:NSBackingStoreBuffered
                                  defer:NO];

                [view setWantsLayer:YES];
                [window setContentView:view];
                [window setTitle:[NSString stringWithUTF8String:plugin->name]];
                [window setAcceptsMouseMovedEvents:YES];
                [window setReleasedWhenClosed:NO];
                [window makeKeyAndOrderFront:nil];
                [window center];
                [NSApp activateIgnoringOtherApps:YES];
                [window makeFirstResponder:view];

                plugin->guiWindow = (__bridge_retained void*)window;
                plugin->guiViewController = (__bridge_retained void*)vc;

                NSLog(@"[auv3] GUI window opened for: %s", plugin->name);
            });
        }];
    });
}

// ─── Parameters ─────────────────────────────────────────────────────────────

uint32_t auv3_parameter_count(AUv3Plugin* plugin) {
    if (!plugin || !plugin->auAudioUnit) return 0;
    AUAudioUnit* au = (__bridge AUAudioUnit*)(plugin->auAudioUnit);
    return (uint32_t)au.parameterTree.allParameters.count;
}

int auv3_set_parameter(AUv3Plugin* plugin, uint32_t index, float value) {
    if (!plugin || !plugin->auAudioUnit) return -1;
    AUAudioUnit* au = (__bridge AUAudioUnit*)(plugin->auAudioUnit);
    NSArray<AUParameter*>* params = au.parameterTree.allParameters;
    if (index >= params.count) return -1;
    [params[index] setValue:value];
    return 0;
}

float auv3_get_parameter(AUv3Plugin* plugin, uint32_t index) {
    if (!plugin || !plugin->auAudioUnit) return 0;
    AUAudioUnit* au = (__bridge AUAudioUnit*)(plugin->auAudioUnit);
    NSArray<AUParameter*>* params = au.parameterTree.allParameters;
    if (index >= params.count) return 0;
    return params[index].value;
}

const char* auv3_get_name(AUv3Plugin* plugin) {
    return plugin ? plugin->name : "";
}

// ─── State (preset) persistence ─────────────────────────────────────────────
// Uses AUAudioUnit.fullState (NSDictionary) archived via NSKeyedArchiver.
// Caller frees returned buffer with free(). Returns NULL on failure.

uint8_t* auv3_get_state(AUv3Plugin* plugin, uint32_t* outLen) {
    if (!plugin || !plugin->auAudioUnit || !outLen) return NULL;
    AUAudioUnit* au = (__bridge AUAudioUnit*)(plugin->auAudioUnit);
    NSDictionary* state = au.fullState;
    if (!state) { *outLen = 0; return NULL; }

    NSError* err = nil;
    NSData* data = [NSKeyedArchiver archivedDataWithRootObject:state
                                         requiringSecureCoding:NO
                                                         error:&err];
    if (err || !data) {
        NSLog(@"[auv3] get_state archive failed: %@", err);
        *outLen = 0;
        return NULL;
    }

    uint8_t* buf = (uint8_t*)malloc(data.length);
    if (!buf) { *outLen = 0; return NULL; }
    memcpy(buf, data.bytes, data.length);
    *outLen = (uint32_t)data.length;
    return buf;
}

int auv3_set_state(AUv3Plugin* plugin, const uint8_t* bytes, uint32_t len) {
    if (!plugin || !plugin->auAudioUnit || !bytes || len == 0) return -1;
    AUAudioUnit* au = (__bridge AUAudioUnit*)(plugin->auAudioUnit);

    NSData* data = [NSData dataWithBytes:bytes length:len];
    NSError* err = nil;
    NSSet* classes = [NSSet setWithArray:@[[NSDictionary class], [NSString class],
                                            [NSNumber class], [NSData class],
                                            [NSArray class]]];
    NSDictionary* state = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                              fromData:data
                                                                 error:&err];
    if (err || !state) {
        NSLog(@"[auv3] set_state unarchive failed: %@", err);
        return -2;
    }

    @try {
        au.fullState = state;
    } @catch (NSException* ex) {
        NSLog(@"[auv3] set_state assignment threw: %@", ex);
        return -3;
    }
    return 0;
}

// ─── Plugin enumeration ─────────────────────────────────────────────────────

typedef struct {
    char name[256];
    char manufacturer[256];
    char type[32]; // "Instrument", "Effect", etc.
} AUv3PluginInfo;

// Returns number of plugins found. Fills `out` up to `maxOut` entries.
uint32_t auv3_list_plugins(AUv3PluginInfo* out, uint32_t maxOut) {
    uint32_t count = 0;

    // Search for instruments (synths)
    AudioComponentDescription descs[] = {
        { kAudioUnitType_MusicDevice, 0, 0, 0, 0 },
        { kAudioUnitType_MusicEffect, 0, 0, 0, 0 },
        { kAudioUnitType_Effect, 0, 0, 0, 0 },
    };
    const char* typeNames[] = { "Instrument", "MusicEffect", "Effect" };

    for (int d = 0; d < 3; d++) {
        AudioComponent comp = NULL;
        while ((comp = AudioComponentFindNext(comp, &descs[d])) != NULL) {
            if (count >= maxOut) return count;

            CFStringRef cfName = NULL;
            AudioComponentCopyName(comp, &cfName);
            if (cfName) {
                NSString* name = (__bridge_transfer NSString*)cfName;

                // Split "Manufacturer: PluginName" format
                NSArray* parts = [name componentsSeparatedByString:@": "];
                NSString* mfr = parts.count > 1 ? parts[0] : @"Unknown";
                NSString* pluginName = parts.count > 1 ? parts[1] : name;

                strncpy(out[count].name, [pluginName UTF8String], 255);
                out[count].name[255] = '\0';
                strncpy(out[count].manufacturer, [mfr UTF8String], 255);
                out[count].manufacturer[255] = '\0';
                strncpy(out[count].type, typeNames[d], 31);
                out[count].type[31] = '\0';
                count++;
            }
        }
    }

    return count;
}

// ─── Event loop ─────────────────────────────────────────────────────────────

void auv3_pump_events(void) {
    // Not used anymore — replaced by auv3_run_main_loop
}

// Application delegate
@interface StrudelBridgeDelegate : NSObject <NSApplicationDelegate>
@end

@implementation StrudelBridgeDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Monitor window creation for debugging
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification* note) {
        NSWindow* win = note.object;
        NSLog(@"[auv3] Window became key: %@ level:%ld frame:%@",
              win.title, (long)win.level, NSStringFromRect(win.frame));
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification* note) {
        NSWindow* win = note.object;
        NSLog(@"[auv3] Window closing: %@", win.title);
    }];
}
@end

static StrudelBridgeDelegate* _appDelegate = nil;

// Start the NSApp run loop. This never returns.
// JUCE's PopupMenu::show() calls CFRunLoopRunInMode + [NSApp nextEventMatchingMask:]
// internally, so [NSApp run] must be the outermost event loop on the main thread.
void auv3_run_main_loop(void) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        _appDelegate = [[StrudelBridgeDelegate alloc] init];
        [app setDelegate:_appDelegate];

        // Menu bar
        NSMenu* menuBar = [[NSMenu alloc] init];
        NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:appMenuItem];
        NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"strudel-vst-bridge"];
        [appMenu addItemWithTitle:@"Quit"
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];
        [app setMainMenu:menuBar];

        NSLog(@"[auv3] Starting [NSApp run] on main thread (isMainThread: %d)",
              [NSThread isMainThread]);

        // [NSApp run] properly handles nested modal event loops (JUCE PopupMenu::show)
        [app run];
    }
}

// Schedule a GUI show on the main thread (safe to call from any thread)
void auv3_show_gui_async(AUv3Plugin* plugin) {
    if (!plugin || !plugin->auAudioUnit) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // If window already exists, just bring it to front
        if (plugin->guiWindow) {
            NSWindow* window = (__bridge NSWindow*)plugin->guiWindow;
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            NSLog(@"[auv3] Brought existing GUI window to front");
            return;
        }

        AUAudioUnit* au = (__bridge AUAudioUnit*)plugin->auAudioUnit;

        [au requestViewControllerWithCompletionHandler:^(AUViewControllerBase* _Nullable vc) {
            if (!vc) {
                NSLog(@"[auv3] No view controller available for GUI");
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                NSView* view = vc.view;
                NSSize viewSize = view.frame.size;
                if (viewSize.width < 1 || viewSize.height < 1) {
                    viewSize = NSMakeSize(800, 600);
                }

                NSLog(@"[auv3] Creating GUI window (%gx%g)", viewSize.width, viewSize.height);

                NSRect frame = NSMakeRect(100, 100, viewSize.width, viewSize.height);
                NSWindow* window = [[NSWindow alloc]
                    initWithContentRect:frame
                              styleMask:(NSWindowStyleMaskTitled |
                                        NSWindowStyleMaskClosable |
                                        NSWindowStyleMaskMiniaturizable |
                                        NSWindowStyleMaskResizable)
                                backing:NSBackingStoreBuffered
                                  defer:NO];

                [view setWantsLayer:YES];
                [window setContentView:view];
                [window setTitle:[NSString stringWithUTF8String:plugin->name]];
                [window setAcceptsMouseMovedEvents:YES];
                [window setReleasedWhenClosed:NO];
                [window makeKeyAndOrderFront:nil];
                [window center];
                [NSApp activateIgnoringOtherApps:YES];
                [window makeFirstResponder:view];

                plugin->guiWindow = (__bridge_retained void*)window;
                plugin->guiViewController = (__bridge_retained void*)vc;

                NSLog(@"[auv3] GUI window opened for: %s", plugin->name);
            });
        }];
    });
}
