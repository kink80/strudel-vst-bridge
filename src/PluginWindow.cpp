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
