// auv3_host.m — AUv3 plugin host with GUI support and live audio routing for macOS.
// Hosts AudioUnit plugins via the modern AUAudioUnit API so that
// the same instance handles both audio rendering and GUI display.
// Also provides a real-time audio I/O path for routing input through
// an effect chain to an output device.

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudioKit/CoreAudioKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <AppKit/AppKit.h>
#include <stdint.h>
#include <string.h>
#include <stdatomic.h>
#include <os/lock.h>

// ─── Types ──────────────────────────────────────────────────────────────────

typedef struct {
    void* auAudioUnit;           // AUAudioUnit* (retained)
    void* renderBlock;           // AURenderBlock (retained)
    void* internalRenderBlock;   // AUInternalRenderBlock (retained) — for v2 effects
    AudioBufferList* outputBufferList;
    AudioBufferList* inputBufferList;  // Pre-allocated input ABL for pullInputBlock
    float* inputBufL;            // Pre-allocated input buffer L
    float* inputBufR;            // Pre-allocated input buffer R
    uint32_t maxFrames;
    double sampleRate;
    int64_t sampleTime;          // Running sample counter for timestamps
    void* guiWindow;             // NSWindow* (retained)
    void* guiViewController;     // NSViewController* (retained)
    char name[256];
    char manufacturer[256];

    // For effect routing: the IOProc writes input audio here before calling render.
    float* _Atomic effectInputL;
    float* _Atomic effectInputR;
    _Atomic uint32_t effectInputFrames;
    int hasInputBus;             // 1 if the plugin has an input bus (is an effect)
    AudioUnit v2AudioUnit;       // v2 AudioUnit reference (for setting render callback)
} AUv3Plugin;

// ─── Audio device info (returned to Rust) ──────────────────────────────────

typedef struct {
    uint32_t deviceId;       // CoreAudio AudioDeviceID
    char name[256];
    char uid[256];
    int isInput;             // 1 = has input channels, 0 = no
    int isOutput;            // 1 = has output channels, 0 = no
    uint32_t inputChannels;
    uint32_t outputChannels;
} AudioDeviceInfo;

// ─── Audio Router — real-time I/O with effect chain ────────────────────────

#define MAX_CHAIN_PLUGINS 16
#define ROUTER_BLOCK_SIZE 256

typedef struct {
    // CoreAudio HAL I/O
    AudioDeviceID inputDevice;
    AudioDeviceID outputDevice;
    AudioDeviceID activeDevice;        // Device the IOProc is attached to (may be aggregate)
    AudioDeviceID aggregateDevice;     // Non-zero if we created an aggregate device
    AudioDeviceIOProcID ioProcId;

    // Effect chain — swapped atomically
    // The audio thread reads chain/chainLen via atomic pointer swap.
    AUv3Plugin* _Atomic chain[MAX_CHAIN_PLUGINS];
    _Atomic int chainLen;

    // Intermediate buffers for chaining effects (allocated once)
    float* bufA_L;
    float* bufA_R;
    float* bufB_L;
    float* bufB_R;
    uint32_t bufSize; // in frames

    // State
    _Atomic int running;
    double sampleRate;
    int64_t sampleTime;

    // Device change callback (set from Rust)
    void (*deviceChangedCallback)(void* ctx);
    void* deviceChangedCtx;
} AudioRouter;

static AudioRouter _router = {0};
static AudioObjectPropertyListenerProc _deviceListListener = NULL;

// ─── v2 AudioUnit input render callback ────────────────────────────────────

// This callback is called by v2 AudioUnits (via AUAudioUnitV2Bridge) to get
// their input audio. We read from the plugin's effectInputL/R pointers.
static OSStatus v2InputRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    AUv3Plugin* plugin = (AUv3Plugin*)inRefCon;
    float* inL = atomic_load(&plugin->effectInputL);
    float* inR = atomic_load(&plugin->effectInputR);
    uint32_t avail = atomic_load(&plugin->effectInputFrames);
    uint32_t frames = (inNumberFrames < avail) ? inNumberFrames : avail;

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        uint32_t ch = ioData->mBuffers[b].mNumberChannels;
        if (ch == 1) {
            float* src = (b == 0) ? inL : inR;
            if (src && ioData->mBuffers[b].mData) {
                memcpy(ioData->mBuffers[b].mData, src, frames * sizeof(float));
            } else if (ioData->mBuffers[b].mData) {
                memset(ioData->mBuffers[b].mData, 0, frames * sizeof(float));
            }
        } else if (ch >= 2 && ioData->mBuffers[b].mData) {
            // Non-interleaved stereo unlikely here, but handle interleaved
            float* dst = (float*)ioData->mBuffers[b].mData;
            for (uint32_t f = 0; f < frames; f++) {
                dst[f * ch] = inL ? inL[f] : 0.0f;
                if (ch >= 2) dst[f * ch + 1] = inR ? inR[f] : 0.0f;
                for (uint32_t c = 2; c < ch; c++) dst[f * ch + c] = 0.0f;
            }
        }
        ioData->mBuffers[b].mDataByteSize = frames * sizeof(float) * ch;
    }
    return noErr;
}

// ─── Plugin lifecycle ───────────────────────────────────────────────────────

// Synchronous wrapper around async AUAudioUnit instantiation.
// Searches across all plugin types: instruments, music effects, and effects.
AUv3Plugin* auv3_load_plugin(const char* componentName, double sampleRate, uint32_t maxFrames) {
    __block AUv3Plugin* result = NULL;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSString* targetName = [NSString stringWithUTF8String:componentName];
    NSString* targetLower = [targetName lowercaseString];

    // Search across all plugin types
    AudioComponentDescription searchDescs[] = {
        { kAudioUnitType_MusicDevice, 0, 0, 0, 0 },
        { kAudioUnitType_MusicEffect, 0, 0, 0, 0 },
        { kAudioUnitType_Effect, 0, 0, 0, 0 },
    };

    AudioComponent found = NULL;
    for (int d = 0; d < 3 && !found; d++) {
        AudioComponent comp = NULL;
        while ((comp = AudioComponentFindNext(comp, &searchDescs[d])) != NULL) {
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
    [AUAudioUnit instantiateWithComponentDescription:desc
                                              options:kAudioComponentInstantiation_LoadInProcess
                                    completionHandler:^(AUAudioUnit* _Nullable auAudioUnit, NSError* _Nullable error) {
        if (error || !auAudioUnit) {
            NSLog(@"[auv3] Failed to instantiate: %@", error);
            dispatch_semaphore_signal(sem);
            return;
        }

        NSError* allocError = nil;

        // Configure format: stereo float, non-interleaved
        AVAudioFormat* format = [[AVAudioFormat alloc]
            initStandardFormatWithSampleRate:sampleRate
                                   channels:2];

        // Set output format
        [auAudioUnit.outputBusses[0] setFormat:format error:&allocError];
        if (allocError) {
            NSLog(@"[auv3] Failed to set output format: %@", allocError);
        }

        // Set input format if the plugin has inputs
        if (auAudioUnit.inputBusses.count > 0) {
            allocError = nil;
            [auAudioUnit.inputBusses[0] setFormat:format error:&allocError];
            if (allocError) {
                NSLog(@"[auv3] Failed to set input format: %@", allocError);
            }
        }

        auAudioUnit.maximumFramesToRender = maxFrames;

        int hasInputBus = (auAudioUnit.inputBusses.count > 0) ? 1 : 0;

        // For effects: try to set outputProvider (native AUv3 only).
        // v2-bridged AUs don't support this — we fall back to pullInputBlock.
        BOOL usesOutputProvider = NO;
        if (hasInputBus) {
            @try {
                // Pre-allocate the plugin struct so we can reference it from the block
                AUv3Plugin* plugin_pre = (AUv3Plugin*)calloc(1, sizeof(AUv3Plugin));
                // We'll set this up properly later — for now just need a pointer
                // Actually, we can't use outputProvider for v2 bridges, so just skip.
                // Check if it's a native AUv3 (not a v2 bridge)
                if ([auAudioUnit respondsToSelector:@selector(setOutputProvider:)]) {
                    usesOutputProvider = YES;
                    NSLog(@"[auv3] Plugin supports setOutputProvider (native AUv3)");
                    free(plugin_pre);
                } else {
                    free(plugin_pre);
                }
            } @catch (NSException *e) {
                NSLog(@"[auv3] outputProvider not supported: %@", e.reason);
            }
        }

        // Allocate render resources
        allocError = nil;
        [auAudioUnit allocateRenderResourcesAndReturnError:&allocError];
        if (allocError) {
            NSLog(@"[auv3] Failed to allocate render resources: %@", allocError);
            dispatch_semaphore_signal(sem);
            return;
        }

        // Get the render block
        AURenderBlock renderBlock = auAudioUnit.renderBlock;
        // Also get the internalRenderBlock — this is the raw render that
        // the v2 bridge uses, and it DOES call the pullInputBlock.
        AUInternalRenderBlock internalBlock = auAudioUnit.internalRenderBlock;
        NSLog(@"[auv3] renderBlock=%p internalRenderBlock=%p hasInput=%d",
              renderBlock, internalBlock, hasInputBus);

        // Create output buffer list (data pointers set per-render call)
        AudioBufferList* abl = (AudioBufferList*)calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
        abl->mNumberBuffers = 2;
        abl->mBuffers[0].mNumberChannels = 1;
        abl->mBuffers[0].mData = NULL;
        abl->mBuffers[1].mNumberChannels = 1;
        abl->mBuffers[1].mData = NULL;

        AUv3Plugin* plugin = (AUv3Plugin*)calloc(1, sizeof(AUv3Plugin));
        plugin->auAudioUnit = (__bridge_retained void*)auAudioUnit;
        plugin->renderBlock = (__bridge_retained void*)[renderBlock copy];
        plugin->internalRenderBlock = (__bridge_retained void*)[internalBlock copy];
        plugin->outputBufferList = abl;
        plugin->maxFrames = maxFrames;
        plugin->sampleRate = sampleRate;
        plugin->hasInputBus = hasInputBus;
        plugin->guiWindow = NULL;
        plugin->guiViewController = NULL;

        // For effects: set up v2 render callback for input
        if (hasInputBus) {
            plugin->inputBufL = (float*)calloc(maxFrames, sizeof(float));
            plugin->inputBufR = (float*)calloc(maxFrames, sizeof(float));
            AudioBufferList* inAbl = (AudioBufferList*)calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
            inAbl->mNumberBuffers = 2;
            inAbl->mBuffers[0].mNumberChannels = 1;
            inAbl->mBuffers[0].mData = plugin->inputBufL;
            inAbl->mBuffers[0].mDataByteSize = maxFrames * sizeof(float);
            inAbl->mBuffers[1].mNumberChannels = 1;
            inAbl->mBuffers[1].mData = plugin->inputBufR;
            inAbl->mBuffers[1].mDataByteSize = maxFrames * sizeof(float);
            plugin->inputBufferList = inAbl;

            // Get the underlying v2 AudioUnit from the AUAudioUnitV2Bridge.
            // The 'audioUnit' property is not public API but is accessible via KVC.
            AudioUnit v2au = NULL;
            @try {
                NSValue* auVal = [auAudioUnit valueForKey:@"audioUnit"];
                if (auVal) {
                    v2au = (AudioUnit)[auVal pointerValue];
                }
            } @catch (NSException *e) {
                NSLog(@"[auv3] Cannot access v2 AudioUnit: %@", e.reason);
            }
            if (v2au) {
                plugin->v2AudioUnit = v2au;
                AURenderCallbackStruct callbackStruct = {
                    .inputProc = v2InputRenderCallback,
                    .inputProcRefCon = plugin,
                };
                OSStatus cbStatus = AudioUnitSetProperty(
                    v2au,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,  // input bus 0
                    &callbackStruct,
                    sizeof(callbackStruct)
                );
                if (cbStatus == noErr) {
                    NSLog(@"[auv3] Installed v2 render callback for effect input");
                } else {
                    NSLog(@"[auv3] Failed to install v2 render callback: %d", (int)cbStatus);
                }
            } else {
                NSLog(@"[auv3] No v2 AudioUnit available (native AUv3 plugin)");
            }
        }

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

    if (plugin->guiWindow) {
        NSWindow* win = (__bridge_transfer NSWindow*)plugin->guiWindow;
        dispatch_async(dispatch_get_main_queue(), ^{
            [win close];
        });
    }
    if (plugin->guiViewController) {
        NSViewController* vc __attribute__((unused)) = (__bridge_transfer NSViewController*)plugin->guiViewController;
    }

    AUAudioUnit* au = (__bridge_transfer AUAudioUnit*)plugin->auAudioUnit;
    [au deallocateRenderResources];

    if (plugin->renderBlock) {
        AURenderBlock block __attribute__((unused)) = (__bridge_transfer AURenderBlock)plugin->renderBlock;
    }
    if (plugin->internalRenderBlock) {
        AUInternalRenderBlock block __attribute__((unused)) = (__bridge_transfer AUInternalRenderBlock)plugin->internalRenderBlock;
    }

    if (plugin->outputBufferList) {
        free(plugin->outputBufferList);
    }
    if (plugin->inputBufferList) {
        free(plugin->inputBufferList);
    }
    free(plugin->inputBufL);
    free(plugin->inputBufR);
    free(plugin);
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

// ─── Audio rendering ────────────────────────────────────────────────────────

int auv3_render(AUv3Plugin* plugin, uint32_t numFrames, float* outLeft, float* outRight) {
    if (!plugin || !plugin->renderBlock || numFrames > plugin->maxFrames) return -1;

    AURenderBlock renderBlock = (__bridge AURenderBlock)(plugin->renderBlock);

    // Point output buffer list directly at caller's buffers — zero-copy
    plugin->outputBufferList->mBuffers[0].mDataByteSize = numFrames * sizeof(float);
    plugin->outputBufferList->mBuffers[0].mData = outLeft;
    plugin->outputBufferList->mBuffers[1].mDataByteSize = numFrames * sizeof(float);
    plugin->outputBufferList->mBuffers[1].mData = outRight;

    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp timestamp = {0};
    timestamp.mSampleTime = (Float64)plugin->sampleTime;
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;

    OSStatus status = renderBlock(&flags, &timestamp, numFrames, 0, plugin->outputBufferList, NULL);
    if (status != noErr) {
        return (int)status;
    }

    plugin->sampleTime += numFrames;
    return 0;
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

// ─── Effect rendering (with audio input) ───────────────────────────────────

// Render through an effect plugin.
// For v2-bridged AUs: the v2InputRenderCallback is already installed on the
// AudioUnit's input bus. We just set the effectInput pointers and call render.
// The AU will call our callback to get its input data.
static int _effectDebugCount = 0;

int auv3_render_effect(AUv3Plugin* plugin, uint32_t numFrames,
                       float* inLeft, float* inRight,
                       float* outLeft, float* outRight) {
    if (!plugin || !plugin->renderBlock) return -1;
    if (numFrames > plugin->maxFrames) numFrames = plugin->maxFrames;

    // Set input pointers for the v2 render callback to read from
    atomic_store(&plugin->effectInputL, inLeft);
    atomic_store(&plugin->effectInputR, inRight);
    atomic_store(&plugin->effectInputFrames, numFrames);

    AURenderBlock renderBlock = (__bridge AURenderBlock)(plugin->renderBlock);

    // Point output buffer list at caller's buffers
    plugin->outputBufferList->mBuffers[0].mDataByteSize = numFrames * sizeof(float);
    plugin->outputBufferList->mBuffers[0].mData = outLeft;
    plugin->outputBufferList->mBuffers[1].mDataByteSize = numFrames * sizeof(float);
    plugin->outputBufferList->mBuffers[1].mData = outRight;

    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp timestamp = {0};
    timestamp.mSampleTime = (Float64)plugin->sampleTime;
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;

    // Call renderBlock with NULL pullInputBlock — the v2 AU uses its
    // installed kAudioUnitProperty_SetRenderCallback instead.
    OSStatus status = renderBlock(&flags, &timestamp, numFrames, 0,
                                  plugin->outputBufferList, NULL);

    if (_effectDebugCount < 5) {
        _effectDebugCount++;
        float maxSample = 0;
        for (uint32_t i = 0; i < numFrames; i++) {
            float absL = outLeft[i] > 0 ? outLeft[i] : -outLeft[i];
            float absR = outRight[i] > 0 ? outRight[i] : -outRight[i];
            if (absL > maxSample) maxSample = absL;
            if (absR > maxSample) maxSample = absR;
        }
        NSLog(@"[effect] render: status=%d peak=%.6f hasInput=%d frames=%u",
              (int)status, maxSample, plugin->hasInputBus, numFrames);
    }

    if (status != noErr) {
        return (int)status;
    }

    // If the plugin replaced our output pointers, copy back
    if (plugin->outputBufferList->mBuffers[0].mData != outLeft &&
        plugin->outputBufferList->mBuffers[0].mData != NULL) {
        memcpy(outLeft, plugin->outputBufferList->mBuffers[0].mData, numFrames * sizeof(float));
    }
    if (plugin->outputBufferList->mBuffers[1].mData != outRight &&
        plugin->outputBufferList->mBuffers[1].mData != NULL) {
        memcpy(outRight, plugin->outputBufferList->mBuffers[1].mData, numFrames * sizeof(float));
    }

    plugin->sampleTime += numFrames;
    return 0;
}

// ─── Audio device enumeration ──────────────────────────────────────────────

static int auv3_device_channel_count(AudioDeviceID deviceId, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(deviceId, &addr, 0, NULL, &dataSize);
    if (status != noErr || dataSize == 0) return 0;

    AudioBufferList* bufList = (AudioBufferList*)malloc(dataSize);
    status = AudioObjectGetPropertyData(deviceId, &addr, 0, NULL, &dataSize, bufList);
    int channels = 0;
    if (status == noErr) {
        for (UInt32 i = 0; i < bufList->mNumberBuffers; i++) {
            channels += bufList->mBuffers[i].mNumberChannels;
        }
    }
    free(bufList);
    return channels;
}

uint32_t auv3_list_audio_devices(AudioDeviceInfo* out, uint32_t maxOut) {
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &dataSize);
    if (status != noErr) return 0;

    uint32_t deviceCount = dataSize / sizeof(AudioDeviceID);
    AudioDeviceID* devices = (AudioDeviceID*)malloc(dataSize);
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &dataSize, devices);
    if (status != noErr) { free(devices); return 0; }

    uint32_t count = 0;
    for (uint32_t i = 0; i < deviceCount && count < maxOut; i++) {
        AudioDeviceID devId = devices[i];

        int inCh = auv3_device_channel_count(devId, kAudioDevicePropertyScopeInput);
        int outCh = auv3_device_channel_count(devId, kAudioDevicePropertyScopeOutput);

        // Skip devices with no channels at all
        if (inCh == 0 && outCh == 0) continue;

        out[count].deviceId = (uint32_t)devId;
        out[count].isInput = (inCh > 0) ? 1 : 0;
        out[count].isOutput = (outCh > 0) ? 1 : 0;
        out[count].inputChannels = (uint32_t)inCh;
        out[count].outputChannels = (uint32_t)outCh;

        // Get device name
        CFStringRef cfName = NULL;
        UInt32 nameSize = sizeof(CFStringRef);
        AudioObjectPropertyAddress nameAddr = {
            .mSelector = kAudioDevicePropertyDeviceNameCFString,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(devId, &nameAddr, 0, NULL, &nameSize, &cfName) == noErr && cfName) {
            CFStringGetCString(cfName, out[count].name, 256, kCFStringEncodingUTF8);
            CFRelease(cfName);
        } else {
            strncpy(out[count].name, "Unknown", 255);
        }

        // Get device UID
        CFStringRef cfUid = NULL;
        UInt32 uidSize = sizeof(CFStringRef);
        AudioObjectPropertyAddress uidAddr = {
            .mSelector = kAudioDevicePropertyDeviceUID,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(devId, &uidAddr, 0, NULL, &uidSize, &cfUid) == noErr && cfUid) {
            CFStringGetCString(cfUid, out[count].uid, 256, kCFStringEncodingUTF8);
            CFRelease(cfUid);
        } else {
            out[count].uid[0] = '\0';
        }

        count++;
    }

    free(devices);
    return count;
}

uint32_t auv3_get_default_input_device(void) {
    AudioDeviceID deviceId = kAudioObjectUnknown;
    UInt32 size = sizeof(AudioDeviceID);
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDefaultInputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceId);
    return (uint32_t)deviceId;
}

uint32_t auv3_get_default_output_device(void) {
    AudioDeviceID deviceId = kAudioObjectUnknown;
    UInt32 size = sizeof(AudioDeviceID);
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceId);
    return (uint32_t)deviceId;
}

// ─── Audio Router ──────────────────────────────────────────────────────────

// CoreAudio IOProc callback — runs on the real-time audio thread.
static int _routerCallCount = 0;

static OSStatus routerIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp* inNow,
    const AudioBufferList* inInputData,
    const AudioTimeStamp* inInputTime,
    AudioBufferList* outOutputData,
    const AudioTimeStamp* inOutputTime,
    void* inClientData
) {
    AudioRouter* router = (AudioRouter*)inClientData;

    if (!atomic_load(&router->running)) {
        for (UInt32 b = 0; b < outOutputData->mNumberBuffers; b++) {
            memset(outOutputData->mBuffers[b].mData, 0, outOutputData->mBuffers[b].mDataByteSize);
        }
        return noErr;
    }

    uint32_t numFrames = outOutputData->mBuffers[0].mDataByteSize / sizeof(float);
    if (numFrames > router->bufSize) numFrames = router->bufSize;

    // Log first callback for debugging
    if (_routerCallCount < 3) {
        _routerCallCount++;
        NSLog(@"[router] IOProc: frames=%u inBufs=%u(ch=%u) outBufs=%u(ch=%u) chainLen=%d",
              numFrames,
              inInputData ? (unsigned)inInputData->mNumberBuffers : 0,
              (inInputData && inInputData->mNumberBuffers > 0) ? (unsigned)inInputData->mBuffers[0].mNumberChannels : 0,
              (unsigned)outOutputData->mNumberBuffers,
              (unsigned)outOutputData->mBuffers[0].mNumberChannels,
              atomic_load(&router->chainLen));
    }

    // Get input audio — handle both interleaved and non-interleaved formats
    float* srcL = router->bufA_L;
    float* srcR = router->bufA_R;

    if (inInputData && inInputData->mNumberBuffers >= 2) {
        // Non-interleaved stereo: 2 buffers, 1 channel each
        uint32_t inFrames = inInputData->mBuffers[0].mDataByteSize / sizeof(float);
        uint32_t copyFrames = (inFrames < numFrames) ? inFrames : numFrames;
        memcpy(srcL, inInputData->mBuffers[0].mData, copyFrames * sizeof(float));
        memcpy(srcR, inInputData->mBuffers[1].mData, copyFrames * sizeof(float));
        if (copyFrames < numFrames) {
            memset(srcL + copyFrames, 0, (numFrames - copyFrames) * sizeof(float));
            memset(srcR + copyFrames, 0, (numFrames - copyFrames) * sizeof(float));
        }
    } else if (inInputData && inInputData->mNumberBuffers >= 1) {
        uint32_t numCh = inInputData->mBuffers[0].mNumberChannels;
        if (numCh >= 2) {
            // Interleaved stereo: 1 buffer, 2+ channels — deinterleave
            float* interleaved = (float*)inInputData->mBuffers[0].mData;
            uint32_t inFrames = inInputData->mBuffers[0].mDataByteSize / (sizeof(float) * numCh);
            uint32_t copyFrames = (inFrames < numFrames) ? inFrames : numFrames;
            for (uint32_t f = 0; f < copyFrames; f++) {
                srcL[f] = interleaved[f * numCh];
                srcR[f] = interleaved[f * numCh + 1];
            }
            if (copyFrames < numFrames) {
                memset(srcL + copyFrames, 0, (numFrames - copyFrames) * sizeof(float));
                memset(srcR + copyFrames, 0, (numFrames - copyFrames) * sizeof(float));
            }
        } else {
            // Mono: duplicate to both channels
            uint32_t inFrames = inInputData->mBuffers[0].mDataByteSize / sizeof(float);
            uint32_t copyFrames = (inFrames < numFrames) ? inFrames : numFrames;
            memcpy(srcL, inInputData->mBuffers[0].mData, copyFrames * sizeof(float));
            memcpy(srcR, inInputData->mBuffers[0].mData, copyFrames * sizeof(float));
        }
    } else {
        memset(srcL, 0, numFrames * sizeof(float));
        memset(srcR, 0, numFrames * sizeof(float));
    }

    // Process through effect chain
    float* dstL = router->bufB_L;
    float* dstR = router->bufB_R;

    int chainLen = atomic_load(&router->chainLen);
    for (int i = 0; i < chainLen && i < MAX_CHAIN_PLUGINS; i++) {
        AUv3Plugin* plugin = atomic_load(&router->chain[i]);
        if (!plugin) continue;

        // Process in chunks if numFrames > plugin's maxFrames
        uint32_t maxF = plugin->maxFrames;
        uint32_t offset = 0;
        int ok = 1;
        while (offset < numFrames) {
            uint32_t chunk = numFrames - offset;
            if (chunk > maxF) chunk = maxF;
            int rc = auv3_render_effect(plugin, chunk,
                                        srcL + offset, srcR + offset,
                                        dstL + offset, dstR + offset);
            if (rc != 0) {
                if (_routerCallCount <= 5) {
                    NSLog(@"[router] Effect render error: %d (plugin=%s, chunk=%u)",
                          rc, plugin->name, chunk);
                }
                ok = 0;
                break;
            }
            offset += chunk;
        }

        if (!ok) {
            // On error, pass through unprocessed
            memcpy(dstL, srcL, numFrames * sizeof(float));
            memcpy(dstR, srcR, numFrames * sizeof(float));
        }

        // Swap src/dst for next effect in chain
        float* tmpL = srcL; srcL = dstL; dstL = tmpL;
        float* tmpR = srcR; srcR = dstR; dstR = tmpR;
    }

    // srcL/srcR now point to the final processed audio — copy to output
    if (outOutputData->mNumberBuffers >= 2) {
        // Non-interleaved stereo
        memcpy(outOutputData->mBuffers[0].mData, srcL, numFrames * sizeof(float));
        memcpy(outOutputData->mBuffers[1].mData, srcR, numFrames * sizeof(float));
    } else if (outOutputData->mNumberBuffers >= 1) {
        uint32_t numCh = outOutputData->mBuffers[0].mNumberChannels;
        float* dst = (float*)outOutputData->mBuffers[0].mData;
        if (numCh >= 2) {
            // Interleaved stereo: interleave L/R into single buffer
            for (uint32_t f = 0; f < numFrames; f++) {
                dst[f * numCh] = srcL[f];
                dst[f * numCh + 1] = srcR[f];
                // Zero any extra channels
                for (uint32_t c = 2; c < numCh; c++) {
                    dst[f * numCh + c] = 0.0f;
                }
            }
        } else {
            // Mono — mix down
            for (uint32_t s = 0; s < numFrames; s++) {
                dst[s] = (srcL[s] + srcR[s]) * 0.5f;
            }
        }
    }

    return noErr;
}

static void router_alloc_buffers(AudioRouter* router, uint32_t frames) {
    if (router->bufSize >= frames) return;
    free(router->bufA_L); free(router->bufA_R);
    free(router->bufB_L); free(router->bufB_R);
    router->bufA_L = (float*)calloc(frames, sizeof(float));
    router->bufA_R = (float*)calloc(frames, sizeof(float));
    router->bufB_L = (float*)calloc(frames, sizeof(float));
    router->bufB_R = (float*)calloc(frames, sizeof(float));
    router->bufSize = frames;
}

static void router_free_buffers(AudioRouter* router) {
    free(router->bufA_L); router->bufA_L = NULL;
    free(router->bufA_R); router->bufA_R = NULL;
    free(router->bufB_L); router->bufB_L = NULL;
    free(router->bufB_R); router->bufB_R = NULL;
    router->bufSize = 0;
}

int auv3_router_set_input(uint32_t deviceId) {
    _router.inputDevice = (AudioDeviceID)deviceId;
    NSLog(@"[router] Input device set to: %u", deviceId);
    return 0;
}

int auv3_router_set_output(uint32_t deviceId) {
    _router.outputDevice = (AudioDeviceID)deviceId;
    NSLog(@"[router] Output device set to: %u", deviceId);
    return 0;
}

int auv3_router_set_chain(AUv3Plugin** plugins, int count) {
    if (count > MAX_CHAIN_PLUGINS) count = MAX_CHAIN_PLUGINS;

    // Store new chain atomically — the audio thread reads these
    for (int i = 0; i < count; i++) {
        atomic_store(&_router.chain[i], plugins[i]);
    }
    // Clear remaining slots
    for (int i = count; i < MAX_CHAIN_PLUGINS; i++) {
        atomic_store(&_router.chain[i], NULL);
    }
    // Update length last (fence via atomic store)
    atomic_store(&_router.chainLen, count);

    // Reset log counters so we get debug output for new chain
    _routerCallCount = 0;
    _effectDebugCount = 0;
    NSLog(@"[router] Effect chain updated: %d plugins", count);
    return 0;
}

// Helper: get a device's UID string (caller must CFRelease)
static CFStringRef router_get_device_uid(AudioDeviceID deviceId) {
    CFStringRef uid = NULL;
    UInt32 size = sizeof(CFStringRef);
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyDeviceUID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(deviceId, &addr, 0, NULL, &size, &uid);
    return uid;
}

// Create a CoreAudio aggregate device that combines two devices into one.
// Uses AudioHardwareCreateAggregateDevice (macOS 10.9+).
// Returns the aggregate AudioDeviceID, or kAudioObjectUnknown on failure.
static AudioDeviceID router_create_aggregate(AudioDeviceID inputDev, AudioDeviceID outputDev) {
    CFStringRef inputUID = router_get_device_uid(inputDev);
    CFStringRef outputUID = router_get_device_uid(outputDev);
    if (!inputUID || !outputUID) {
        NSLog(@"[router] Failed to get device UIDs (input=%p output=%p)", inputUID, outputUID);
        if (inputUID) CFRelease(inputUID);
        if (outputUID) CFRelease(outputUID);
        return kAudioObjectUnknown;
    }

    NSLog(@"[router] Creating aggregate: input UID=%@ output UID=%@",
          (__bridge NSString*)inputUID, (__bridge NSString*)outputUID);

    // Build sub-device list
    // Each sub-device dict needs kAudioSubDeviceUIDKey
    NSDictionary* inputSubdev = @{
        (__bridge NSString*)CFSTR(kAudioSubDeviceUIDKey): (__bridge NSString*)inputUID,
    };
    NSDictionary* outputSubdev = @{
        (__bridge NSString*)CFSTR(kAudioSubDeviceUIDKey): (__bridge NSString*)outputUID,
    };

    NSString* aggUID = [NSString stringWithFormat:@"com.strudel.agg.%u.%u",
                        (unsigned)inputDev, (unsigned)outputDev];

    // Build aggregate device description dictionary
    NSDictionary* aggDesc = @{
        (__bridge NSString*)CFSTR(kAudioAggregateDeviceUIDKey): aggUID,
        (__bridge NSString*)CFSTR(kAudioAggregateDeviceNameKey): @"Strudel Audio Router",
        (__bridge NSString*)CFSTR(kAudioAggregateDeviceSubDeviceListKey): @[inputSubdev, outputSubdev],
        (__bridge NSString*)CFSTR(kAudioAggregateDeviceMasterSubDeviceKey): (__bridge NSString*)outputUID,
        (__bridge NSString*)CFSTR(kAudioAggregateDeviceIsPrivateKey): @YES,
        (__bridge NSString*)CFSTR(kAudioAggregateDeviceIsStackedKey): @NO,
    };

    AudioDeviceID aggDevId = kAudioObjectUnknown;
    OSStatus status = AudioHardwareCreateAggregateDevice(
        (__bridge CFDictionaryRef)aggDesc, &aggDevId
    );

    CFRelease(inputUID);
    CFRelease(outputUID);

    if (status != noErr) {
        NSLog(@"[router] AudioHardwareCreateAggregateDevice failed: %d", (int)status);
        return kAudioObjectUnknown;
    }

    NSLog(@"[router] Created aggregate device: %u (input=%u, output=%u)",
          (unsigned)aggDevId, (unsigned)inputDev, (unsigned)outputDev);
    return aggDevId;
}

static void router_destroy_aggregate(AudioDeviceID aggDevId) {
    if (aggDevId == kAudioObjectUnknown) return;

    OSStatus status = AudioHardwareDestroyAggregateDevice(aggDevId);
    if (status != noErr) {
        NSLog(@"[router] Failed to destroy aggregate device %u: %d",
              (unsigned)aggDevId, (int)status);
    } else {
        NSLog(@"[router] Destroyed aggregate device: %u", (unsigned)aggDevId);
    }
}

int auv3_router_start(void) {
    if (atomic_load(&_router.running)) {
        NSLog(@"[router] Already running");
        return 0;
    }

    if (_router.inputDevice == kAudioObjectUnknown) {
        _router.inputDevice = auv3_get_default_input_device();
    }
    if (_router.outputDevice == kAudioObjectUnknown) {
        _router.outputDevice = auv3_get_default_output_device();
    }

    if (_router.inputDevice == kAudioObjectUnknown || _router.outputDevice == kAudioObjectUnknown) {
        NSLog(@"[router] No input or output device available");
        return -1;
    }

    _router.sampleRate = 48000.0;
    router_alloc_buffers(&_router, 4096);

    // Determine which device to attach the IOProc to
    _router.aggregateDevice = kAudioObjectUnknown;

    if (_router.inputDevice == _router.outputDevice) {
        // Same device — use it directly
        _router.activeDevice = _router.outputDevice;
        NSLog(@"[router] Same device for I/O: %u", (unsigned)_router.activeDevice);
    } else {
        // Different devices — create an aggregate device
        AudioDeviceID aggId = router_create_aggregate(_router.inputDevice, _router.outputDevice);
        if (aggId == kAudioObjectUnknown) {
            NSLog(@"[router] Failed to create aggregate device, falling back to output device only");
            _router.activeDevice = _router.outputDevice;
        } else {
            _router.aggregateDevice = aggId;
            _router.activeDevice = aggId;
        }
    }

    OSStatus status = AudioDeviceCreateIOProcID(
        _router.activeDevice,
        routerIOProc,
        &_router,
        &_router.ioProcId
    );
    if (status != noErr) {
        NSLog(@"[router] Failed to create IOProc: %d", (int)status);
        if (_router.aggregateDevice != kAudioObjectUnknown) {
            router_destroy_aggregate(_router.aggregateDevice);
            _router.aggregateDevice = kAudioObjectUnknown;
        }
        return -1;
    }

    status = AudioDeviceStart(_router.activeDevice, _router.ioProcId);
    if (status != noErr) {
        NSLog(@"[router] Failed to start audio device: %d", (int)status);
        AudioDeviceDestroyIOProcID(_router.activeDevice, _router.ioProcId);
        _router.ioProcId = NULL;
        if (_router.aggregateDevice != kAudioObjectUnknown) {
            router_destroy_aggregate(_router.aggregateDevice);
            _router.aggregateDevice = kAudioObjectUnknown;
        }
        return -1;
    }

    atomic_store(&_router.running, 1);
    NSLog(@"[router] Started: input=%u output=%u active=%u aggregate=%u",
          (unsigned)_router.inputDevice, (unsigned)_router.outputDevice,
          (unsigned)_router.activeDevice, (unsigned)_router.aggregateDevice);
    return 0;
}

int auv3_router_stop(void) {
    if (!atomic_load(&_router.running)) {
        NSLog(@"[router] Not running");
        return 0;
    }

    atomic_store(&_router.running, 0);

    if (_router.ioProcId) {
        AudioDeviceStop(_router.activeDevice, _router.ioProcId);
        AudioDeviceDestroyIOProcID(_router.activeDevice, _router.ioProcId);
        _router.ioProcId = NULL;
    }

    // Clean up aggregate device if we created one
    if (_router.aggregateDevice != kAudioObjectUnknown) {
        router_destroy_aggregate(_router.aggregateDevice);
        _router.aggregateDevice = kAudioObjectUnknown;
    }
    _router.activeDevice = kAudioObjectUnknown;

    NSLog(@"[router] Stopped");
    return 0;
}

int auv3_router_is_running(void) {
    return atomic_load(&_router.running);
}

// ─── Device hotplug listener ───────────────────────────────────────────────

typedef void (*DeviceChangedCallback)(void* ctx);
static DeviceChangedCallback _deviceChangedCb = NULL;
static void* _deviceChangedCtx = NULL;

static OSStatus deviceListListenerProc(
    AudioObjectID inObjectID,
    UInt32 inNumberAddresses,
    const AudioObjectPropertyAddress* inAddresses,
    void* inClientData
) {
    NSLog(@"[router] Audio device list changed");
    if (_deviceChangedCb) {
        _deviceChangedCb(_deviceChangedCtx);
    }
    return noErr;
}

void auv3_register_device_change_callback(DeviceChangedCallback cb, void* ctx) {
    _deviceChangedCb = cb;
    _deviceChangedCtx = ctx;

    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &addr,
        deviceListListenerProc,
        NULL
    );

    NSLog(@"[router] Registered device change listener");
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
