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

    void scanPlugins();
    std::vector<ws::PluginInfo> getAvailablePlugins() const;
    std::string createInstance (const std::string& label, const std::string& pluginName);
    void deleteInstance (const std::string& label);
    std::vector<ws::InstanceInfo> listInstances() const;
    juce::AudioPluginInstance* getInstance (const std::string& label) const;

    struct RenderResult {
        std::vector<float> left, right;
        uint32_t numSamples = 0;
    };
    RenderResult renderNote (const std::string& label, uint8_t note,
                             float velocity, float duration,
                             const std::map<std::string, float>& params);

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
