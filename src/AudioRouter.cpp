#include "AudioRouter.h"
#include "PluginHost.h"

AudioRouter::AudioRouter (PluginHost& host) : pluginHost (host)
{
    deviceManager.addChangeListener (this);
}

AudioRouter::~AudioRouter()
{
    stop();
    deviceManager.removeChangeListener (this);
    delete activeChain.load();
}

std::vector<ws::AudioDeviceEntry> AudioRouter::getDevices()
{
    std::vector<ws::AudioDeviceEntry> result;
    int index = 0;
    for (auto* type : deviceManager.getAvailableDeviceTypes())
    {
        for (auto& name : type->getDeviceNames (true))
        {
            ws::AudioDeviceEntry entry;
            entry.index = index++;
            entry.name = name.toStdString();
            entry.isInput = true;
            entry.isOutput = false;
            entry.inputChannels = 2;
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
    // prepareToPlay must happen on the message thread for VST3 plugins
    if (! juce::MessageManager::getInstance()->isThisTheMessageThread())
    {
        juce::WaitableEvent done;
        juce::MessageManager::callAsync ([&]() {
            setEffectChain (labels);
            done.signal();
        });
        done.wait();
        return;
    }

    auto* newChain = new ChainState();
    newChain->labels = labels;
    for (auto& label : labels)
    {
        auto* proc = pluginHost.getInstance (label);
        if (proc)
        {
            proc->setNonRealtime (false);
            proc->prepareToPlay (currentSampleRate, currentBlockSize);
            newChain->processors.push_back (proc);
        }
    }

    auto* old = activeChain.exchange (newChain);
    if (old)
        juce::MessageManager::callAsync ([old]() { delete old; });

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
    // Copy input to output
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
        for (auto* proc : chain->processors)
        {
            if (! proc) continue;

            // Create buffer with enough channels for the plugin
            int pluginChannels = std::max (proc->getTotalNumInputChannels(),
                                           proc->getTotalNumOutputChannels());
            int bufChannels = std::max (numOutputChannels, pluginChannels);

            if (bufChannels <= numOutputChannels)
            {
                // Plugin fits in output buffer — process in-place
                juce::AudioBuffer<float> buffer (outputChannelData, numOutputChannels, numSamples);
                juce::MidiBuffer midi;
                proc->processBlock (buffer, midi);
            }
            else
            {
                // Plugin needs more channels — use temporary buffer
                juce::AudioBuffer<float> buffer (bufChannels, numSamples);
                buffer.clear();
                for (int ch = 0; ch < numOutputChannels; ch++)
                    buffer.copyFrom (ch, 0, outputChannelData[ch], numSamples);

                juce::MidiBuffer midi;
                proc->processBlock (buffer, midi);

                for (int ch = 0; ch < numOutputChannels; ch++)
                    memcpy (outputChannelData[ch], buffer.getReadPointer (ch),
                            (size_t)numSamples * sizeof (float));
            }
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
