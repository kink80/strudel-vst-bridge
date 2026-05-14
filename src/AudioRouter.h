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

    std::vector<ws::AudioDeviceEntry> getDevices();
    int getDefaultInputIndex() const;
    int getDefaultOutputIndex() const;

    bool setInputDevice (const std::string& name);
    bool setOutputDevice (const std::string& name);

    void setEffectChain (const std::vector<std::string>& labels);

    bool start();
    void stop();
    bool isRunning() const;

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

    struct ChainState {
        std::vector<std::string> labels;
        std::vector<juce::AudioPluginInstance*> processors;
    };
    std::atomic<ChainState*> activeChain { nullptr };
    juce::CriticalSection chainLock;

    bool running = false;
    double currentSampleRate = 48000.0;
    int currentBlockSize = 512;
};
