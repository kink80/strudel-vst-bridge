#include <JuceHeader.h>
#include "PluginHost.h"
#include "AudioRouter.h"
#include "WsServer.h"
#include "WsProtocol.h"

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
