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
    // VST3 requires instantiation + prepareToPlay on the message thread.
    // If we're not on it, block until the message thread does the work.
    if (! juce::MessageManager::getInstance()->isThisTheMessageThread())
    {
        std::string result;
        juce::WaitableEvent done;
        juce::MessageManager::callAsync ([&]() {
            result = createInstance (label, pluginName);
            done.signal();
        });
        done.wait();
        return result;
    }

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
    if (! juce::MessageManager::getInstance()->isThisTheMessageThread())
    {
        juce::WaitableEvent done;
        juce::MessageManager::callAsync ([&]() {
            deleteInstance (label);
            done.signal();
        });
        done.wait();
        return;
    }

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

    // Use the plugin's actual channel count (must be >= 2 for stereo output)
    int numChannels = std::max (2, std::max (proc->getTotalNumInputChannels(),
                                              proc->getTotalNumOutputChannels()));

    auto totalSamples = (int)(duration * sampleRate);
    auto releaseSamples = (int)(2.0 * sampleRate);
    auto maxSamples = totalSamples + releaseSamples;

    result.left.resize (maxSamples, 0.0f);
    result.right.resize (maxSamples, 0.0f);

    juce::MidiBuffer midiBuffer;
    midiBuffer.addEvent (juce::MidiMessage::noteOn (1, (int)note, velocity), 0);

    int rendered = 0;
    while (rendered < totalSamples)
    {
        int frames = std::min (blockSize, totalSamples - rendered);
        juce::AudioBuffer<float> buffer (numChannels, frames);
        buffer.clear();

        juce::MidiBuffer blockMidi;
        if (rendered == 0) blockMidi = midiBuffer;

        proc->processBlock (buffer, blockMidi);

        memcpy (result.left.data() + rendered, buffer.getReadPointer (0), frames * sizeof (float));
        if (numChannels >= 2)
            memcpy (result.right.data() + rendered, buffer.getReadPointer (1), frames * sizeof (float));
        else
            memcpy (result.right.data() + rendered, buffer.getReadPointer (0), frames * sizeof (float));
        rendered += frames;
    }

    // Note off + release tail
    {
        juce::MidiBuffer offMidi;
        offMidi.addEvent (juce::MidiMessage::noteOff (1, (int)note), 0);
        juce::MidiBuffer emptyMidi;

        int silentBlocks = 0;
        while (rendered < maxSamples && silentBlocks < 10)
        {
            int frames = std::min (blockSize, maxSamples - rendered);
            juce::AudioBuffer<float> buffer (numChannels, frames);
            buffer.clear();

            juce::MidiBuffer& midi = (rendered == totalSamples) ? offMidi : emptyMidi;
            proc->processBlock (buffer, midi);

            float rms = 0;
            for (int i = 0; i < frames; i++)
            {
                rms += buffer.getSample (0, i) * buffer.getSample (0, i);
                if (numChannels >= 2)
                    rms += buffer.getSample (1, i) * buffer.getSample (1, i);
            }
            rms /= (frames * std::min (numChannels, 2));

            memcpy (result.left.data() + rendered, buffer.getReadPointer (0), frames * sizeof (float));
            if (numChannels >= 2)
                memcpy (result.right.data() + rendered, buffer.getReadPointer (1), frames * sizeof (float));
            else
                memcpy (result.right.data() + rendered, buffer.getReadPointer (0), frames * sizeof (float));
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
