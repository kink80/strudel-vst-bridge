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

    static void show (juce::AudioProcessor* processor, const std::string& label);
    static void close (const std::string& label);

private:
    std::string label;
    static std::map<std::string, std::unique_ptr<PluginWindow>> windows;
};
