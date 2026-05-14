# JUCE Bridge Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the strudel-vst-bridge as a JUCE C++ application that hosts AU/VST3/CLAP plugins via JUCE's AudioProcessor API, replacing the manual ObjC AUv3 hosting that can't properly feed audio to effects.

**Architecture:** A headless JUCE GUI app (needed for plugin windows) with a WebSocket server running on a background thread. JUCE's `AudioDeviceManager` handles audio I/O. Plugin instances are `AudioPluginInstance` objects. The MIDI render path creates an offline `AudioBuffer`, feeds MIDI + renders blocks, returns PCM. The routing path uses a real-time audio callback that chains `processBlock()` calls. The WebSocket protocol is identical to the current Rust bridge — the browser side needs zero changes.

**Tech Stack:** JUCE 8.x (FetchContent), CMake, C++17, [IXWebSocket](https://github.com/machinezone/IXWebSocket) (FetchContent, BSD-licensed header-only WebSocket lib with built-in server support)

**Key Design Decisions:**
- Keep the exact same WebSocket JSON protocol so the JS client (`superdough/vst.mjs`) and UI (`RoutingTab.jsx`, `VstTab.jsx`) work unchanged
- Binary audio response format stays identical: `[u32 requestId][u32 numSamples][f32[] L][f32[] R]`
- Plugin GUIs use JUCE's `AudioProcessorEditor` in real windows — works for all plugin formats
- No Rust, no Objective-C — pure C++ with JUCE abstractions

---

## File Structure

```
strudel-vst-bridge/
  CMakeLists.txt                    # Root build — FetchContent for JUCE + IXWebSocket
  src/
    Main.cpp                        # JUCE app entry, creates WsServer + PluginHost
    PluginHost.h / PluginHost.cpp   # Plugin loading, instance registry, MIDI rendering
    AudioRouter.h / AudioRouter.cpp # Real-time audio I/O with effect chain
    WsServer.h / WsServer.cpp       # WebSocket server, JSON protocol dispatch
    WsProtocol.h / WsProtocol.cpp  # JSON message parsing + serialization
    PluginWindow.h / PluginWindow.cpp # Native plugin editor windows
```

Each file has one responsibility:
- **Main.cpp** — App lifecycle, wires everything together
- **PluginHost** — Owns `AudioPluginFormatManager`, `KnownPluginList`, instance map. Scans, loads, destroys plugins. Renders MIDI notes to audio buffers (offline).
- **AudioRouter** — Owns `AudioDeviceManager`. Implements `AudioIODeviceCallback`. Chains effect instances in `audioDeviceIOCallbackWithContext()`. Manages device selection.
- **WsServer** — Runs IXWebSocket server on port 8765. Dispatches JSON messages to PluginHost/AudioRouter. Sends responses. Manages client connections for broadcast.
- **WsProtocol** — Parse incoming JSON into typed structs. Serialize responses to JSON/binary. No business logic.
- **PluginWindow** — Creates/shows/hides native editor windows per plugin instance.

---

### Task 1: CMake Project + Build Skeleton

**Files:**
- Create: `CMakeLists.txt`
- Create: `src/Main.cpp`

- [ ] **Step 1: Create CMakeLists.txt**

```cmake
cmake_minimum_required(VERSION 3.22)
project(strudel-vst-bridge VERSION 0.3.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# JUCE
FetchContent_Declare(juce
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG 8.0.6
    GIT_SHALLOW ON)
FetchContent_MakeAvailable(juce)

# IXWebSocket
FetchContent_Declare(ixwebsocket
    GIT_REPOSITORY https://github.com/machinezone/IXWebSocket.git
    GIT_TAG v11.4.6
    GIT_SHALLOW ON)
set(USE_TLS OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(ixwebsocket)

juce_add_gui_app(strudel-vst-bridge
    PRODUCT_NAME "strudel-vst-bridge"
    COMPANY_NAME "Strudel"
    BUNDLE_ID "cc.strudel.vstbridge")

target_sources(strudel-vst-bridge PRIVATE
    src/Main.cpp
    src/PluginHost.cpp
    src/AudioRouter.cpp
    src/WsServer.cpp
    src/WsProtocol.cpp
    src/PluginWindow.cpp)

target_include_directories(strudel-vst-bridge PRIVATE src)

target_compile_definitions(strudel-vst-bridge PRIVATE
    JUCE_WEB_BROWSER=0
    JUCE_USE_CURL=0
    JUCE_PLUGINHOST_AU=1
    JUCE_PLUGINHOST_VST3=1
    JUCE_PLUGINHOST_LV2=0
    JUCE_APPLICATION_NAME_STRING="$<TARGET_PROPERTY:strudel-vst-bridge,JUCE_PRODUCT_NAME>"
    JUCE_APPLICATION_VERSION_STRING="$<TARGET_PROPERTY:strudel-vst-bridge,VERSION>")

target_link_libraries(strudel-vst-bridge PRIVATE
    juce::juce_audio_basics
    juce::juce_audio_devices
    juce::juce_audio_formats
    juce::juce_audio_processors
    juce::juce_audio_utils
    juce::juce_core
    juce::juce_events
    juce::juce_gui_basics
    juce::juce_gui_extra
    ixwebsocket::ixwebsocket
    juce::juce_recommended_config_flags
    juce::juce_recommended_warning_flags)
```

- [ ] **Step 2: Create minimal Main.cpp**

```cpp
#include <JuceHeader.h>

class StrudelBridgeApp : public juce::JUCEApplication
{
public:
    const juce::String getApplicationName() override { return "strudel-vst-bridge"; }
    const juce::String getApplicationVersion() override { return "0.3.0"; }

    void initialise (const juce::String&) override
    {
        juce::Logger::writeToLog ("strudel-vst-bridge starting...");
    }

    void shutdown() override
    {
        juce::Logger::writeToLog ("strudel-vst-bridge shutting down.");
    }
};

START_JUCE_APPLICATION (StrudelBridgeApp)
```

- [ ] **Step 3: Build to verify JUCE fetches and compiles**

```bash
cd /Users/stecl/work2/strudel-vst-bridge
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Debug
cmake --build . --target strudel-vst-bridge -j8
```

Expected: Compiles. JUCE + IXWebSocket fetched. Binary produced.

- [ ] **Step 4: Commit**

```bash
git add CMakeLists.txt src/Main.cpp
git commit -m "feat: JUCE project skeleton with CMake + IXWebSocket"
```

---

### Task 2: WsProtocol — JSON Message Parsing

**Files:**
- Create: `src/WsProtocol.h`
- Create: `src/WsProtocol.cpp`

This is pure data transformation — no dependencies on PluginHost or AudioRouter.

- [ ] **Step 1: Create WsProtocol.h**

```cpp
#pragma once
#include <JuceHeader.h>
#include <variant>
#include <vector>
#include <string>
#include <map>

namespace ws {

// ─── Incoming messages ─────────────────────────────────────────────────────

struct CreateInstance { std::string label; std::string pluginName; };
struct DeleteInstance { std::string label; };
struct ListInstances {};
struct Render {
    uint32_t requestId;
    std::string pluginId;
    uint8_t note;
    float velocity = 0.8f;
    float duration = 1.0f;
    std::map<std::string, float> params;
};
struct ShowGui { std::string pluginId; };
struct ListPlugins {};
struct ListAudioDevices {};
struct SetAudioInput { int deviceIndex; };
struct SetAudioOutput { int deviceIndex; };
struct SetEffectChain { std::vector<std::string> chain; };
struct StartAudio {};
struct StopAudio {};
struct GetAudioStatus {};

using IncomingMessage = std::variant<
    CreateInstance, DeleteInstance, ListInstances,
    Render, ShowGui, ListPlugins,
    ListAudioDevices, SetAudioInput, SetAudioOutput,
    SetEffectChain, StartAudio, StopAudio, GetAudioStatus>;

/** Parse a JSON text message. Returns std::nullopt on failure. */
std::optional<IncomingMessage> parseMessage (const std::string& json);

// ─── Outgoing messages ─────────────────────────────────────────────────────

struct PluginInfo { std::string name; std::string manufacturer; std::string pluginType; };
struct InstanceInfo { std::string label; std::string pluginName; };
struct AudioDeviceEntry {
    int index;
    std::string name;
    bool isInput;
    bool isOutput;
    int inputChannels;
    int outputChannels;
};

std::string makePluginList (const std::vector<PluginInfo>& plugins);
std::string makeInstanceList (const std::vector<InstanceInfo>& instances);
std::string makeInstanceCreated (const std::string& label, const std::string& pluginName);
std::string makeInstanceDeleted (const std::string& label);
std::string makeError (const std::string& message, const std::string& pluginId = {}, int requestId = -1);
std::string makeGuiOpened (const std::string& pluginId);
std::string makeAudioDeviceList (const std::vector<AudioDeviceEntry>& devices,
                                  int defaultInput, int defaultOutput);
std::string makeAudioStatus (bool running, const std::string& message = {});
std::string makeEffectChainSet (const std::vector<std::string>& chain);
std::string makeDeviceListChanged();

/** Encode audio response as binary: [u32 requestId][u32 numSamples][f32[] L][f32[] R] */
std::vector<uint8_t> encodeAudioResponse (uint32_t requestId,
                                           const float* left, const float* right,
                                           uint32_t numSamples);

} // namespace ws
```

- [ ] **Step 2: Create WsProtocol.cpp**

```cpp
#include "WsProtocol.h"

namespace ws {

std::optional<IncomingMessage> parseMessage (const std::string& jsonStr)
{
    auto json = juce::JSON::parse (jsonStr);
    if (! json.isObject()) return std::nullopt;

    auto obj = json.getDynamicObject();
    auto type = obj->getProperty ("type").toString().toStdString();

    if (type == "create_instance")
        return CreateInstance {
            obj->getProperty ("label").toString().toStdString(),
            obj->getProperty ("pluginName").toString().toStdString()
        };
    if (type == "delete_instance")
        return DeleteInstance { obj->getProperty ("label").toString().toStdString() };
    if (type == "list_instances")
        return ListInstances {};
    if (type == "render") {
        Render r;
        r.requestId = (uint32_t)(int)obj->getProperty ("requestId");
        r.pluginId  = obj->getProperty ("pluginId").toString().toStdString();
        r.note      = (uint8_t)(int)obj->getProperty ("note");
        r.velocity  = obj->hasProperty ("velocity") ? (float)obj->getProperty ("velocity") : 0.8f;
        r.duration  = obj->hasProperty ("duration") ? (float)obj->getProperty ("duration") : 1.0f;
        if (auto* p = obj->getProperty ("params").getDynamicObject())
            for (auto& kv : p->getProperties())
                r.params[kv.name.toString().toStdString()] = (float)kv.value;
        return r;
    }
    if (type == "show_gui")
        return ShowGui { obj->getProperty ("pluginId").toString().toStdString() };
    if (type == "list_plugins")
        return ListPlugins {};
    if (type == "list_audio_devices")
        return ListAudioDevices {};
    if (type == "set_audio_input")
        return SetAudioInput { (int)obj->getProperty ("deviceId") };
    if (type == "set_audio_output")
        return SetAudioOutput { (int)obj->getProperty ("deviceId") };
    if (type == "set_effect_chain") {
        SetEffectChain sc;
        if (auto* arr = obj->getProperty ("chain").getArray())
            for (auto& v : *arr)
                sc.chain.push_back (v.toString().toStdString());
        return sc;
    }
    if (type == "start_audio")  return StartAudio {};
    if (type == "stop_audio")   return StopAudio {};
    if (type == "get_audio_status") return GetAudioStatus {};

    return std::nullopt;
}

// ─── JSON helpers ──────────────────────────────────────────────────────────

static std::string toJson (const juce::DynamicObject& obj)
{
    return juce::JSON::toString (juce::var (&obj), true).toStdString();
}

std::string makePluginList (const std::vector<PluginInfo>& plugins)
{
    auto obj = new juce::DynamicObject();
    obj->setProperty ("type", "plugin_list");
    juce::Array<juce::var> arr;
    for (auto& p : plugins) {
        auto e = new juce::DynamicObject();
        e->setProperty ("name", juce::String (p.name));
        e->setProperty ("manufacturer", juce::String (p.manufacturer));
        e->setProperty ("pluginType", juce::String (p.pluginType));
        arr.add (juce::var (e));
    }
    obj->setProperty ("plugins", arr);
    return toJson (*obj);
}

std::string makeInstanceList (const std::vector<InstanceInfo>& instances)
{
    auto obj = new juce::DynamicObject();
    obj->setProperty ("type", "instance_list");
    juce::Array<juce::var> arr;
    for (auto& i : instances) {
        auto e = new juce::DynamicObject();
        e->setProperty ("label", juce::String (i.label));
        e->setProperty ("pluginName", juce::String (i.pluginName));
        arr.add (juce::var (e));
    }
    obj->setProperty ("instances", arr);
    return toJson (*obj);
}

std::string makeInstanceCreated (const std::string& label, const std::string& pluginName)
{
    auto obj = new juce::DynamicObject();
    obj->setProperty ("type", "instance_created");
    obj->setProperty ("label", juce::String (label));
    obj->setProperty ("pluginName", juce::String (pluginName));
    obj->setProperty ("params", juce::Array<juce::var>());
    return toJson (*obj);
}

std::string makeInstanceDeleted (const std::string& label)
{
    auto obj = new juce::DynamicObject();
    obj->setProperty ("type", "instance_deleted");
    obj->setProperty ("label", juce::String (label));
    return toJson (*obj);
}

std::string makeError (const std::string& message, const std::string& pluginId, int requestId)
{
    auto obj = new juce::DynamicObject();
    obj->setProperty ("type", "error");
    obj->setProperty ("message", juce::String (message));
    if (! pluginId.empty()) obj->setProperty ("pluginId", juce::String (pluginId));
    if (requestId >= 0)     obj->setProperty ("requestId", requestId);
    return toJson (*obj);
}

std::string makeGuiOpened (const std::string& pluginId)
{
    auto obj = new juce::DynamicObject();
    obj->setProperty ("type", "gui_opened");
    obj->setProperty ("pluginId", juce::String (pluginId));
    return toJson (*obj);
}

std::string makeAudioDeviceList (const std::vector<AudioDeviceEntry>& devices,
                                  int defaultInput, int defaultOutput)
{
    auto obj = new juce::DynamicObject();
    obj->setProperty ("type", "audio_device_list");
    juce::Array<juce::var> arr;
    for (auto& d : devices) {
        auto e = new juce::DynamicObject();
        e->setProperty ("deviceId", d.index);
        e->setProperty ("name", juce::String (d.name));
        e->setProperty ("isInput", d.isInput);
        e->setProperty ("isOutput", d.isOutput);
        e->setProperty ("inputChannels", d.inputChannels);
        e->setProperty ("outputChannels", d.outputChannels);
        arr.add (juce::var (e));
    }
    obj->setProperty ("devices", arr);
    obj->setProperty ("defaultInput", defaultInput);
    obj->setProperty ("defaultOutput", defaultOutput);
    return toJson (*obj);
}

std::string makeAudioStatus (bool running, const std::string& message)
{
    auto obj = new juce::DynamicObject();
    obj->setProperty ("type", "audio_status");
    obj->setProperty ("running", running);
    if (! message.empty()) obj->setProperty ("message", juce::String (message));
    return toJson (*obj);
}

std::string makeEffectChainSet (const std::vector<std::string>& chain)
{
    auto obj = new juce::DynamicObject();
    obj->setProperty ("type", "effect_chain_set");
    juce::Array<juce::var> arr;
    for (auto& l : chain) arr.add (juce::String (l));
    obj->setProperty ("chain", arr);
    return toJson (*obj);
}

std::string makeDeviceListChanged()
{
    return R"({"type":"device_list_changed"})";
}

std::vector<uint8_t> encodeAudioResponse (uint32_t requestId,
                                           const float* left, const float* right,
                                           uint32_t numSamples)
{
    size_t totalBytes = 8 + (size_t)numSamples * 2 * sizeof (float);
    std::vector<uint8_t> buf (totalBytes);
    memcpy (buf.data(), &requestId, 4);
    memcpy (buf.data() + 4, &numSamples, 4);
    memcpy (buf.data() + 8, left, numSamples * sizeof (float));
    memcpy (buf.data() + 8 + numSamples * sizeof (float), right, numSamples * sizeof (float));
    return buf;
}

} // namespace ws
```

- [ ] **Step 3: Create stub files for remaining sources (so it compiles)**

Create empty stubs for `PluginHost.h`, `PluginHost.cpp`, `AudioRouter.h`, `AudioRouter.cpp`, `WsServer.h`, `WsServer.cpp`, `PluginWindow.h`, `PluginWindow.cpp` — just empty files with `#pragma once` / includes.

- [ ] **Step 4: Build**

```bash
cd build && cmake --build . --target strudel-vst-bridge -j8
```

- [ ] **Step 5: Commit**

```bash
git add src/WsProtocol.h src/WsProtocol.cpp
git commit -m "feat: WebSocket protocol parser and serializer"
```

---

### Task 3: PluginHost — Plugin Scanning + Instance Management

**Files:**
- Create: `src/PluginHost.h`
- Create: `src/PluginHost.cpp`

- [ ] **Step 1: Create PluginHost.h**

```cpp
#pragma once
#include <JuceHeader.h>
#include <map>
#include <string>
#include <functional>
#include "WsProtocol.h"

class PluginHost
{
public:
    PluginHost();
    ~PluginHost();

    /** Scan for available plugins (AU, VST3). Call once at startup. */
    void scanPlugins();

    /** Get list of all available plugins. */
    std::vector<ws::PluginInfo> getAvailablePlugins() const;

    /** Create a named plugin instance. Returns error string on failure. */
    std::string createInstance (const std::string& label, const std::string& pluginName);

    /** Delete a named instance. */
    void deleteInstance (const std::string& label);

    /** Get list of active instances. */
    std::vector<ws::InstanceInfo> listInstances() const;

    /** Get a plugin instance by label. Returns nullptr if not found. */
    juce::AudioPluginInstance* getInstance (const std::string& label) const;

    /** Render a MIDI note through a plugin instance (offline). Thread-safe. */
    struct RenderResult {
        std::vector<float> left, right;
        uint32_t numSamples = 0;
    };
    RenderResult renderNote (const std::string& label, uint8_t note,
                             float velocity, float duration,
                             const std::map<std::string, float>& params);

    /** Show the native GUI editor for a plugin instance. Must call from message thread. */
    void showGui (const std::string& label);

    static constexpr double sampleRate = 48000.0;
    static constexpr int blockSize = 2048;

private:
    juce::AudioPluginFormatManager formatManager;
    juce::KnownPluginList knownPlugins;

    struct Instance {
        std::string pluginName;
        std::unique_ptr<juce::AudioPluginInstance> processor;
    };
    std::map<std::string, Instance> instances;
    mutable juce::CriticalSection lock;

    juce::PluginDescription findPlugin (const std::string& name) const;
};
```

- [ ] **Step 2: Create PluginHost.cpp**

```cpp
#include "PluginHost.h"
#include "PluginWindow.h"

PluginHost::PluginHost()
{
    formatManager.addDefaultFormats();
}

PluginHost::~PluginHost()
{
    juce::ScopedLock sl (lock);
    instances.clear();
}

void PluginHost::scanPlugins()
{
    for (auto* format : formatManager.getFormats())
    {
        juce::PluginDirectoryScanner scanner (
            knownPlugins, *format,
            format->getDefaultLocationsToSearch(),
            true, juce::File(), false);

        juce::String name;
        while (scanner.scanNextFile (true, name))
            juce::Logger::writeToLog ("Scanned: " + name);
    }
    juce::Logger::writeToLog ("Plugin scan complete: "
        + juce::String (knownPlugins.getNumTypes()) + " plugins found");
}

std::vector<ws::PluginInfo> PluginHost::getAvailablePlugins() const
{
    std::vector<ws::PluginInfo> result;
    for (auto& desc : knownPlugins.getTypes())
    {
        ws::PluginInfo info;
        info.name = desc.name.toStdString();
        info.manufacturer = desc.manufacturerName.toStdString();
        if (desc.isInstrument)
            info.pluginType = "Instrument";
        else
            info.pluginType = "Effect";
        result.push_back (info);
    }
    return result;
}

juce::PluginDescription PluginHost::findPlugin (const std::string& name) const
{
    auto nameLower = juce::String (name).toLowerCase();
    for (auto& desc : knownPlugins.getTypes())
        if (desc.name.toLowerCase().contains (nameLower))
            return desc;
    return {};
}

std::string PluginHost::createInstance (const std::string& label, const std::string& pluginName)
{
    juce::ScopedLock sl (lock);
    if (instances.count (label))
        return "Instance '" + label + "' already exists";

    auto desc = findPlugin (pluginName);
    if (desc.name.isEmpty())
        return "Plugin not found: " + pluginName;

    juce::String errorMsg;
    auto instance = formatManager.createPluginInstance (desc, sampleRate, blockSize, errorMsg);
    if (! instance)
        return "Failed to load: " + errorMsg.toStdString();

    instance->prepareToPlay (sampleRate, blockSize);
    instance->setNonRealtime (true);

    juce::Logger::writeToLog ("Instance created: '" + juce::String (label)
        + "' -> " + desc.name);

    instances[label] = { pluginName, std::move (instance) };
    return {};
}

void PluginHost::deleteInstance (const std::string& label)
{
    juce::ScopedLock sl (lock);
    auto it = instances.find (label);
    if (it != instances.end())
    {
        it->second.processor->releaseResources();
        instances.erase (it);
        juce::Logger::writeToLog ("Instance deleted: '" + juce::String (label) + "'");
    }
}

std::vector<ws::InstanceInfo> PluginHost::listInstances() const
{
    juce::ScopedLock sl (lock);
    std::vector<ws::InstanceInfo> result;
    for (auto& [label, inst] : instances)
        result.push_back ({ label, inst.pluginName });
    return result;
}

juce::AudioPluginInstance* PluginHost::getInstance (const std::string& label) const
{
    juce::ScopedLock sl (lock);
    auto it = instances.find (label);
    return it != instances.end() ? it->second.processor.get() : nullptr;
}

PluginHost::RenderResult PluginHost::renderNote (
    const std::string& label, uint8_t note,
    float velocity, float duration,
    const std::map<std::string, float>& params)
{
    RenderResult result;

    juce::AudioPluginInstance* proc = nullptr;
    {
        juce::ScopedLock sl (lock);
        auto it = instances.find (label);
        if (it == instances.end()) return result;
        proc = it->second.processor.get();
    }

    auto totalSamples = (int)(duration * sampleRate);
    auto releaseSamples = (int)(2.0 * sampleRate);
    auto maxSamples = totalSamples + releaseSamples;

    result.left.resize (maxSamples, 0.0f);
    result.right.resize (maxSamples, 0.0f);

    juce::MidiBuffer midiBuffer;
    // Note on at sample 0
    midiBuffer.addEvent (juce::MidiMessage::noteOn (1, (int)note, velocity), 0);

    int rendered = 0;
    while (rendered < totalSamples)
    {
        int frames = std::min (blockSize, totalSamples - rendered);
        juce::AudioBuffer<float> buffer (2, frames);
        buffer.clear();

        // Only send MIDI on first block
        juce::MidiBuffer blockMidi;
        if (rendered == 0) blockMidi = midiBuffer;

        proc->processBlock (buffer, blockMidi);

        memcpy (result.left.data() + rendered, buffer.getReadPointer (0), frames * sizeof (float));
        memcpy (result.right.data() + rendered, buffer.getReadPointer (1), frames * sizeof (float));
        rendered += frames;
    }

    // Note off
    {
        juce::MidiBuffer offMidi;
        offMidi.addEvent (juce::MidiMessage::noteOff (1, (int)note), 0);

        int silentBlocks = 0;
        while (rendered < maxSamples && silentBlocks < 10)
        {
            int frames = std::min (blockSize, maxSamples - rendered);
            juce::AudioBuffer<float> buffer (2, frames);
            buffer.clear();

            proc->processBlock (buffer, rendered == totalSamples ? offMidi : juce::MidiBuffer());

            float rms = 0;
            for (int i = 0; i < frames; i++)
            {
                rms += buffer.getSample (0, i) * buffer.getSample (0, i);
                rms += buffer.getSample (1, i) * buffer.getSample (1, i);
            }
            rms /= (frames * 2);

            memcpy (result.left.data() + rendered, buffer.getReadPointer (0), frames * sizeof (float));
            memcpy (result.right.data() + rendered, buffer.getReadPointer (1), frames * sizeof (float));
            rendered += frames;

            if (rms < 1e-6f) silentBlocks++;
            else silentBlocks = 0;
        }
    }

    result.left.resize (rendered);
    result.right.resize (rendered);
    result.numSamples = (uint32_t)rendered;
    return result;
}

void PluginHost::showGui (const std::string& label)
{
    auto* proc = getInstance (label);
    if (proc)
        PluginWindow::show (proc, label);
}
```

- [ ] **Step 3: Build and verify**

```bash
cd build && cmake --build . --target strudel-vst-bridge -j8
```

- [ ] **Step 4: Commit**

```bash
git add src/PluginHost.h src/PluginHost.cpp
git commit -m "feat: PluginHost with scanning, instances, and MIDI rendering"
```

---

### Task 4: PluginWindow — Native Editor Windows

**Files:**
- Create: `src/PluginWindow.h`
- Create: `src/PluginWindow.cpp`

- [ ] **Step 1: Create PluginWindow.h**

```cpp
#pragma once
#include <JuceHeader.h>
#include <map>
#include <string>

class PluginWindow : public juce::DocumentWindow
{
public:
    PluginWindow (juce::AudioProcessorEditor* editor, const std::string& title);
    ~PluginWindow() override;

    void closeButtonPressed() override;

    /** Show or bring to front a window for the given processor. */
    static void show (juce::AudioProcessor* processor, const std::string& label);

    /** Close window for a given label. */
    static void close (const std::string& label);

private:
    std::string label;
    static std::map<std::string, std::unique_ptr<PluginWindow>> windows;
};
```

- [ ] **Step 2: Create PluginWindow.cpp**

```cpp
#include "PluginWindow.h"

std::map<std::string, std::unique_ptr<PluginWindow>> PluginWindow::windows;

PluginWindow::PluginWindow (juce::AudioProcessorEditor* editor, const std::string& title)
    : DocumentWindow (title, juce::Colours::darkgrey, DocumentWindow::allButtons),
      label (title)
{
    setContentOwned (editor, true);
    setResizable (true, false);
    centreWithSize (getWidth(), getHeight());
    setVisible (true);
    toFront (true);
}

PluginWindow::~PluginWindow()
{
    clearContentComponent();
}

void PluginWindow::closeButtonPressed()
{
    setVisible (false);
}

void PluginWindow::show (juce::AudioProcessor* processor, const std::string& label)
{
    jassert (juce::MessageManager::getInstance()->isThisTheMessageThread());

    auto it = windows.find (label);
    if (it != windows.end() && it->second)
    {
        it->second->toFront (true);
        return;
    }

    auto* editor = processor->createEditor();
    if (! editor)
    {
        juce::Logger::writeToLog ("No editor for: " + juce::String (label));
        return;
    }

    windows[label] = std::make_unique<PluginWindow> (editor, label);
}

void PluginWindow::close (const std::string& label)
{
    windows.erase (label);
}
```

- [ ] **Step 3: Build**

```bash
cd build && cmake --build . --target strudel-vst-bridge -j8
```

- [ ] **Step 4: Commit**

```bash
git add src/PluginWindow.h src/PluginWindow.cpp
git commit -m "feat: native plugin editor windows"
```

---

### Task 5: AudioRouter — Real-time Audio I/O with Effect Chain

**Files:**
- Create: `src/AudioRouter.h`
- Create: `src/AudioRouter.cpp`

- [ ] **Step 1: Create AudioRouter.h**

```cpp
#pragma once
#include <JuceHeader.h>
#include <vector>
#include <string>
#include <functional>
#include "WsProtocol.h"

class PluginHost;

class AudioRouter : public juce::AudioIODeviceCallback,
                    public juce::ChangeListener
{
public:
    AudioRouter (PluginHost& host);
    ~AudioRouter() override;

    /** Get list of audio devices. */
    std::vector<ws::AudioDeviceEntry> getDevices() const;
    int getDefaultInputIndex() const;
    int getDefaultOutputIndex() const;

    /** Set input/output device by name or index. */
    bool setInputDevice (const std::string& name);
    bool setOutputDevice (const std::string& name);

    /** Set the effect chain (labels of plugin instances). */
    void setEffectChain (const std::vector<std::string>& labels);

    /** Start/stop audio processing. */
    bool start();
    void stop();
    bool isRunning() const;

    /** Register callback for device list changes. */
    std::function<void()> onDeviceListChanged;

    juce::AudioDeviceManager& getDeviceManager() { return deviceManager; }

private:
    void audioDeviceIOCallbackWithContext (
        const float* const* inputChannelData, int numInputChannels,
        float* const* outputChannelData, int numOutputChannels,
        int numSamples,
        const juce::AudioIODeviceCallbackContext& context) override;

    void audioDeviceAboutToStart (juce::AudioIODevice* device) override;
    void audioDeviceStopped() override;

    void changeListenerCallback (juce::ChangeBroadcaster* source) override;

    PluginHost& pluginHost;
    juce::AudioDeviceManager deviceManager;

    // Effect chain — swapped atomically
    struct ChainState {
        std::vector<std::string> labels;
        std::vector<juce::AudioPluginInstance*> processors;
    };
    std::atomic<ChainState*> activeChain { nullptr };
    ChainState* pendingChain = nullptr;
    juce::CriticalSection chainLock;

    // Intermediate buffers for effect processing
    juce::AudioBuffer<float> effectBuffer;
    juce::MidiBuffer emptyMidi;

    bool running = false;
    double currentSampleRate = 48000.0;
    int currentBlockSize = 512;
};
```

- [ ] **Step 2: Create AudioRouter.cpp**

```cpp
#include "AudioRouter.h"
#include "PluginHost.h"

AudioRouter::AudioRouter (PluginHost& host) : pluginHost (host)
{
    // Listen for device changes
    deviceManager.addChangeListener (this);
}

AudioRouter::~AudioRouter()
{
    stop();
    deviceManager.removeChangeListener (this);
    delete activeChain.load();
    delete pendingChain;
}

std::vector<ws::AudioDeviceEntry> AudioRouter::getDevices() const
{
    std::vector<ws::AudioDeviceEntry> result;
    auto* currentDevice = deviceManager.getCurrentAudioDevice();

    // List input devices
    auto& types = deviceManager.getAvailableDeviceTypes();
    int index = 0;
    for (auto* type : types)
    {
        for (auto& name : type->getDeviceNames (true))
        {
            ws::AudioDeviceEntry entry;
            entry.index = index++;
            entry.name = name.toStdString();
            entry.isInput = true;
            entry.isOutput = false;
            entry.inputChannels = 2; // Approximate
            entry.outputChannels = 0;
            result.push_back (entry);
        }
        for (auto& name : type->getDeviceNames (false))
        {
            ws::AudioDeviceEntry entry;
            entry.index = index++;
            entry.name = name.toStdString();
            entry.isInput = false;
            entry.isOutput = true;
            entry.inputChannels = 0;
            entry.outputChannels = 2;
            result.push_back (entry);
        }
    }
    return result;
}

int AudioRouter::getDefaultInputIndex() const { return 0; }
int AudioRouter::getDefaultOutputIndex() const { return 0; }

bool AudioRouter::setInputDevice (const std::string& name)
{
    auto setup = deviceManager.getAudioDeviceSetup();
    setup.inputDeviceName = juce::String (name);
    auto err = deviceManager.setAudioDeviceSetup (setup, true);
    return err.isEmpty();
}

bool AudioRouter::setOutputDevice (const std::string& name)
{
    auto setup = deviceManager.getAudioDeviceSetup();
    setup.outputDeviceName = juce::String (name);
    auto err = deviceManager.setAudioDeviceSetup (setup, true);
    return err.isEmpty();
}

void AudioRouter::setEffectChain (const std::vector<std::string>& labels)
{
    auto* newChain = new ChainState();
    newChain->labels = labels;
    for (auto& label : labels)
    {
        auto* proc = pluginHost.getInstance (label);
        if (proc)
        {
            // Prepare for real-time playback
            proc->setNonRealtime (false);
            proc->prepareToPlay (currentSampleRate, currentBlockSize);
            newChain->processors.push_back (proc);
        }
    }

    juce::ScopedLock sl (chainLock);
    auto* old = activeChain.exchange (newChain);
    // Defer deletion of old chain
    if (old)
    {
        juce::MessageManager::callAsync ([old]() { delete old; });
    }

    juce::Logger::writeToLog ("Effect chain updated: "
        + juce::String ((int)labels.size()) + " plugins");
}

bool AudioRouter::start()
{
    if (running) return true;

    auto err = deviceManager.initialise (2, 2, nullptr, true);
    if (err.isNotEmpty())
    {
        juce::Logger::writeToLog ("Audio init failed: " + err);
        return false;
    }

    deviceManager.addAudioCallback (this);
    running = true;
    juce::Logger::writeToLog ("Audio router started");
    return true;
}

void AudioRouter::stop()
{
    if (! running) return;
    deviceManager.removeAudioCallback (this);
    running = false;
    juce::Logger::writeToLog ("Audio router stopped");
}

bool AudioRouter::isRunning() const { return running; }

void AudioRouter::audioDeviceIOCallbackWithContext (
    const float* const* inputChannelData, int numInputChannels,
    float* const* outputChannelData, int numOutputChannels,
    int numSamples,
    const juce::AudioIODeviceCallbackContext&)
{
    // Start with input audio
    for (int ch = 0; ch < numOutputChannels; ch++)
    {
        if (ch < numInputChannels && inputChannelData[ch])
            memcpy (outputChannelData[ch], inputChannelData[ch], numSamples * sizeof (float));
        else
            memset (outputChannelData[ch], 0, numSamples * sizeof (float));
    }

    // Process through effect chain
    auto* chain = activeChain.load (std::memory_order_acquire);
    if (chain && ! chain->processors.empty())
    {
        juce::AudioBuffer<float> buffer (outputChannelData, numOutputChannels, numSamples);
        juce::MidiBuffer midi;

        for (auto* proc : chain->processors)
        {
            if (proc)
                proc->processBlock (buffer, midi);
        }
    }
}

void AudioRouter::audioDeviceAboutToStart (juce::AudioIODevice* device)
{
    currentSampleRate = device->getCurrentSampleRate();
    currentBlockSize = device->getCurrentBufferSizeSamples();
    juce::Logger::writeToLog ("Audio device starting: "
        + device->getName() + " @ " + juce::String (currentSampleRate)
        + "Hz, " + juce::String (currentBlockSize) + " samples");
}

void AudioRouter::audioDeviceStopped()
{
    juce::Logger::writeToLog ("Audio device stopped");
}

void AudioRouter::changeListenerCallback (juce::ChangeBroadcaster*)
{
    if (onDeviceListChanged)
        onDeviceListChanged();
}
```

- [ ] **Step 3: Build**

```bash
cd build && cmake --build . --target strudel-vst-bridge -j8
```

- [ ] **Step 4: Commit**

```bash
git add src/AudioRouter.h src/AudioRouter.cpp
git commit -m "feat: AudioRouter with JUCE device I/O and effect chain"
```

---

### Task 6: WsServer — WebSocket Server + Message Dispatch

**Files:**
- Create: `src/WsServer.h`
- Create: `src/WsServer.cpp`

- [ ] **Step 1: Create WsServer.h**

```cpp
#pragma once
#include <JuceHeader.h>
#include <ixwebsocket/IXWebSocketServer.h>
#include <set>
#include <mutex>

class PluginHost;
class AudioRouter;

class WsServer : public juce::Thread
{
public:
    WsServer (PluginHost& host, AudioRouter& router, int port = 8765);
    ~WsServer() override;

    /** Broadcast a text message to all connected clients. */
    void broadcast (const std::string& message);

private:
    void run() override;
    void handleMessage (const std::string& text, std::shared_ptr<ix::WebSocket> ws);

    PluginHost& pluginHost;
    AudioRouter& audioRouter;
    int port;

    ix::WebSocketServer server;
    std::set<std::shared_ptr<ix::WebSocket>> clients;
    std::mutex clientsMutex;
};
```

- [ ] **Step 2: Create WsServer.cpp**

```cpp
#include "WsServer.h"
#include "PluginHost.h"
#include "AudioRouter.h"
#include "WsProtocol.h"

WsServer::WsServer (PluginHost& host, AudioRouter& router, int port)
    : Thread ("WsServer"), pluginHost (host), audioRouter (router),
      port (port), server (port, "0.0.0.0")
{
}

WsServer::~WsServer()
{
    server.stop();
    stopThread (2000);
}

void WsServer::broadcast (const std::string& message)
{
    std::lock_guard<std::mutex> lock (clientsMutex);
    for (auto& ws : clients)
        ws->send (message);
}

void WsServer::run()
{
    server.setOnClientMessageCallback (
        [this] (std::shared_ptr<ix::ConnectionState> connState,
                ix::WebSocket& ws,
                const ix::WebSocketMessagePtr& msg)
    {
        auto wsPtr = ws.shared_from_this_hack();

        if (msg->type == ix::WebSocketMessageType::Open)
        {
            juce::Logger::writeToLog ("Client connected: " + juce::String (connState->getRemoteIp()));
            std::lock_guard<std::mutex> lock (clientsMutex);
            clients.insert (wsPtr);
        }
        else if (msg->type == ix::WebSocketMessageType::Close)
        {
            juce::Logger::writeToLog ("Client disconnected");
            std::lock_guard<std::mutex> lock (clientsMutex);
            clients.erase (wsPtr);
        }
        else if (msg->type == ix::WebSocketMessageType::Message && ! msg->binary)
        {
            handleMessage (msg->str, wsPtr);
        }
    });

    auto res = server.listen();
    if (! res.first)
    {
        juce::Logger::writeToLog ("WebSocket server failed to listen: "
            + juce::String (res.second));
        return;
    }

    server.start();
    juce::Logger::writeToLog ("WebSocket server listening on port " + juce::String (port));

    // Keep thread alive until signaled
    while (! threadShouldExit())
        wait (100);
}

void WsServer::handleMessage (const std::string& text, std::shared_ptr<ix::WebSocket> ws)
{
    auto msg = ws::parseMessage (text);
    if (! msg.has_value())
    {
        ws->send (ws::makeError ("Invalid message"));
        return;
    }

    std::visit ([&] (auto&& m) {
        using T = std::decay_t<decltype(m)>;

        if constexpr (std::is_same_v<T, ws::CreateInstance>)
        {
            auto err = pluginHost.createInstance (m.label, m.pluginName);
            if (err.empty())
                ws->send (ws::makeInstanceCreated (m.label, m.pluginName));
            else
                ws->send (ws::makeError (err, m.label));
        }
        else if constexpr (std::is_same_v<T, ws::DeleteInstance>)
        {
            pluginHost.deleteInstance (m.label);
            ws->send (ws::makeInstanceDeleted (m.label));
        }
        else if constexpr (std::is_same_v<T, ws::ListInstances>)
        {
            ws->send (ws::makeInstanceList (pluginHost.listInstances()));
        }
        else if constexpr (std::is_same_v<T, ws::Render>)
        {
            // Render on a background thread to not block the WS
            auto label = m.pluginId;
            auto requestId = m.requestId;
            auto note = m.note;
            auto vel = m.velocity;
            auto dur = m.duration;
            auto params = m.params;
            auto wsRef = ws;
            auto* host = &pluginHost;

            juce::Thread::launch ([=]() {
                auto result = host->renderNote (label, note, vel, dur, params);
                if (result.numSamples > 0)
                {
                    auto binary = ws::encodeAudioResponse (
                        requestId, result.left.data(), result.right.data(), result.numSamples);
                    wsRef->sendBinary (ix::IXWebSocketSendData (
                        reinterpret_cast<const char*>(binary.data()), binary.size()));
                }
                else
                {
                    wsRef->send (ws::makeError ("Render failed", label, (int)requestId));
                }
            });
        }
        else if constexpr (std::is_same_v<T, ws::ShowGui>)
        {
            juce::MessageManager::callAsync ([this, label = m.pluginId, wsRef = ws]() {
                pluginHost.showGui (label);
                wsRef->send (ws::makeGuiOpened (label));
            });
        }
        else if constexpr (std::is_same_v<T, ws::ListPlugins>)
        {
            ws->send (ws::makePluginList (pluginHost.getAvailablePlugins()));
        }
        else if constexpr (std::is_same_v<T, ws::ListAudioDevices>)
        {
            ws->send (ws::makeAudioDeviceList (
                audioRouter.getDevices(),
                audioRouter.getDefaultInputIndex(),
                audioRouter.getDefaultOutputIndex()));
        }
        else if constexpr (std::is_same_v<T, ws::SetAudioInput>)
        {
            // Find device name by index from device list
            auto devices = audioRouter.getDevices();
            for (auto& d : devices) {
                if (d.index == m.deviceIndex && d.isInput) {
                    audioRouter.setInputDevice (d.name);
                    break;
                }
            }
            ws->send (ws::makeAudioStatus (audioRouter.isRunning()));
        }
        else if constexpr (std::is_same_v<T, ws::SetAudioOutput>)
        {
            auto devices = audioRouter.getDevices();
            for (auto& d : devices) {
                if (d.index == m.deviceIndex && d.isOutput) {
                    audioRouter.setOutputDevice (d.name);
                    break;
                }
            }
            ws->send (ws::makeAudioStatus (audioRouter.isRunning()));
        }
        else if constexpr (std::is_same_v<T, ws::SetEffectChain>)
        {
            audioRouter.setEffectChain (m.chain);
            ws->send (ws::makeEffectChainSet (m.chain));
        }
        else if constexpr (std::is_same_v<T, ws::StartAudio>)
        {
            bool ok = audioRouter.start();
            ws->send (ws::makeAudioStatus (ok, ok ? "Audio started" : "Failed to start"));
        }
        else if constexpr (std::is_same_v<T, ws::StopAudio>)
        {
            audioRouter.stop();
            ws->send (ws::makeAudioStatus (false, "Audio stopped"));
        }
        else if constexpr (std::is_same_v<T, ws::GetAudioStatus>)
        {
            ws->send (ws::makeAudioStatus (audioRouter.isRunning()));
        }
    }, *msg);
}
```

Note: The `shared_from_this_hack()` method may not exist on IXWebSocket. We may need to capture the raw pointer or use a different mechanism. This will be adjusted during implementation if the API differs.

- [ ] **Step 3: Build**

```bash
cd build && cmake --build . --target strudel-vst-bridge -j8
```

- [ ] **Step 4: Commit**

```bash
git add src/WsServer.h src/WsServer.cpp
git commit -m "feat: WebSocket server with full protocol dispatch"
```

---

### Task 7: Main.cpp — Wire Everything Together

**Files:**
- Modify: `src/Main.cpp`

- [ ] **Step 1: Update Main.cpp**

```cpp
#include <JuceHeader.h>
#include "PluginHost.h"
#include "AudioRouter.h"
#include "WsServer.h"

class StrudelBridgeApp : public juce::JUCEApplication
{
public:
    const juce::String getApplicationName() override { return "strudel-vst-bridge"; }
    const juce::String getApplicationVersion() override { return "0.3.0"; }

    void initialise (const juce::String&) override
    {
        juce::Logger::writeToLog ("strudel-vst-bridge v0.3.0 starting...");

        pluginHost = std::make_unique<PluginHost>();
        pluginHost->scanPlugins();

        audioRouter = std::make_unique<AudioRouter> (*pluginHost);

        wsServer = std::make_unique<WsServer> (*pluginHost, *audioRouter);
        wsServer->startThread();

        // Notify browser clients when devices change
        audioRouter->onDeviceListChanged = [this]() {
            if (wsServer)
                wsServer->broadcast (ws::makeDeviceListChanged());
        };

        juce::Logger::writeToLog ("strudel-vst-bridge ready.");
        juce::Logger::writeToLog ("WebSocket: ws://127.0.0.1:8765");
    }

    void shutdown() override
    {
        wsServer.reset();
        audioRouter.reset();
        pluginHost.reset();
        juce::Logger::writeToLog ("strudel-vst-bridge shut down.");
    }

private:
    std::unique_ptr<PluginHost> pluginHost;
    std::unique_ptr<AudioRouter> audioRouter;
    std::unique_ptr<WsServer> wsServer;
};

START_JUCE_APPLICATION (StrudelBridgeApp)
```

- [ ] **Step 2: Build and run**

```bash
cd build && cmake --build . --target strudel-vst-bridge -j8
./strudel-vst-bridge_artefacts/Debug/strudel-vst-bridge
```

Expected: App starts, scans plugins, WebSocket server listens on 8765.

- [ ] **Step 3: Test with strudel**

Open strudel in browser. Go to VST tab — should connect and show plugin list. Go to Routing tab — should show devices. Create an effect instance, add to chain, start audio. Audio should flow from input through effect to output.

- [ ] **Step 4: Commit**

```bash
git add src/Main.cpp
git commit -m "feat: wire up JUCE bridge — fully functional"
```

---

### Task 8: Clean Up Old Rust/ObjC Code

**Files:**
- Delete or archive: `src/main.rs`, `src/auv3_host.m`, `Cargo.toml`, `build.rs`

- [ ] **Step 1: Move old code to `old/` for reference**

```bash
mkdir -p old
mv Cargo.toml Cargo.lock build.rs old/ 2>/dev/null
mv src/main.rs src/auv3_host.m old/
rm -rf target/
```

- [ ] **Step 2: Update .gitignore for CMake**

Add to `.gitignore`:
```
build/
.cache/
compile_commands.json
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: archive old Rust/ObjC code, CMake build is primary"
```

---

## Notes for Implementation

1. **IXWebSocket API differences**: The `shared_from_this_hack()` in WsServer.cpp is a placeholder. IXWebSocket's server callback provides the WebSocket reference differently — check the actual API and adjust. The callback signature is `(std::shared_ptr<ix::ConnectionState>, ix::WebSocket&, const ix::WebSocketMessagePtr&)`. You'll need to capture the WebSocket by reference or pointer.

2. **Plugin scan performance**: The initial scan can take 30-60 seconds. Consider caching the `KnownPluginList` to a file and only rescanning on request.

3. **Thread safety for plugin processBlock**: The same `AudioPluginInstance` should not be called from both the MIDI render thread and the audio callback simultaneously. If a plugin is in the effect chain (realtime), MIDI render requests for that same instance should be rejected or queued.

4. **Device enumeration**: The current JS client uses integer `deviceId` from CoreAudio. JUCE uses device names. The protocol may need adjustment — the simplest fix is to use sequential indices in the device list and map back to names on the C++ side (which the plan already does).

5. **Binary send**: IXWebSocket's `sendBinary()` takes `const std::string&` or a span-like type. The exact API for sending raw bytes should be checked at implementation time.
