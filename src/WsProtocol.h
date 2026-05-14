#pragma once
#include <JuceHeader.h>
#include <variant>
#include <vector>
#include <string>
#include <map>
#include <optional>

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
