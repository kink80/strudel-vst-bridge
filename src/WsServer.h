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

    void broadcast (const std::string& message);

private:
    void run() override;
    void handleMessage (const std::string& text, ix::WebSocket& ws);

    PluginHost& pluginHost;
    AudioRouter& audioRouter;
    int port;

    ix::WebSocketServer server;
    std::set<ix::WebSocket*> clients;
    std::mutex clientsMutex;
};
