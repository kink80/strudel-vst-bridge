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
    for (auto* ws : clients)
        ws->send (message);
}

void WsServer::run()
{
    server.setOnClientMessageCallback (
        [this] (std::shared_ptr<ix::ConnectionState> connState,
                ix::WebSocket& ws,
                const ix::WebSocketMessagePtr& msg)
    {
        if (msg->type == ix::WebSocketMessageType::Open)
        {
            juce::Logger::writeToLog ("Client connected: " + juce::String (connState->getRemoteIp()));
            std::lock_guard<std::mutex> lock (clientsMutex);
            clients.insert (&ws);
        }
        else if (msg->type == ix::WebSocketMessageType::Close)
        {
            juce::Logger::writeToLog ("Client disconnected");
            std::lock_guard<std::mutex> lock (clientsMutex);
            clients.erase (&ws);
        }
        else if (msg->type == ix::WebSocketMessageType::Message && ! msg->binary)
        {
            handleMessage (msg->str, ws);
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

    while (! threadShouldExit())
        wait (100);
}

void WsServer::handleMessage (const std::string& text, ix::WebSocket& ws)
{
    auto msg = ws::parseMessage (text);
    if (! msg.has_value())
    {
        ws.send (ws::makeError ("Invalid message"));
        return;
    }

    std::visit ([&] (auto&& m) {
        using T = std::decay_t<decltype(m)>;

        if constexpr (std::is_same_v<T, ws::CreateInstance>)
        {
            auto err = pluginHost.createInstance (m.label, m.pluginName);
            if (err.empty())
                ws.send (ws::makeInstanceCreated (m.label, m.pluginName));
            else
                ws.send (ws::makeError (err, m.label));
        }
        else if constexpr (std::is_same_v<T, ws::DeleteInstance>)
        {
            pluginHost.deleteInstance (m.label);
            ws.send (ws::makeInstanceDeleted (m.label));
        }
        else if constexpr (std::is_same_v<T, ws::ListInstances>)
        {
            ws.send (ws::makeInstanceList (pluginHost.listInstances()));
        }
        else if constexpr (std::is_same_v<T, ws::Render>)
        {
            auto label = m.pluginId;
            auto requestId = m.requestId;
            auto note = m.note;
            auto vel = m.velocity;
            auto dur = m.duration;
            auto params = m.params;
            auto* wsPtr = &ws;
            auto* host = &pluginHost;

            juce::Thread::launch ([=]() {
                auto result = host->renderNote (label, note, vel, dur, params);
                if (result.numSamples > 0)
                {
                    auto binary = ws::encodeAudioResponse (
                        requestId, result.left.data(), result.right.data(), result.numSamples);
                    std::string binaryStr (reinterpret_cast<const char*>(binary.data()), binary.size());
                    wsPtr->sendBinary (binaryStr);
                }
                else
                {
                    wsPtr->send (ws::makeError ("Render failed", label, (int)requestId));
                }
            });
        }
        else if constexpr (std::is_same_v<T, ws::ShowGui>)
        {
            auto label = m.pluginId;
            auto* wsPtr = &ws;
            juce::MessageManager::callAsync ([this, label, wsPtr]() {
                pluginHost.showGui (label);
                wsPtr->send (ws::makeGuiOpened (label));
            });
        }
        else if constexpr (std::is_same_v<T, ws::ListPlugins>)
        {
            ws.send (ws::makePluginList (pluginHost.getAvailablePlugins()));
        }
        else if constexpr (std::is_same_v<T, ws::ListAudioDevices>)
        {
            ws.send (ws::makeAudioDeviceList (
                audioRouter.getDevices(),
                audioRouter.getDefaultInputIndex(),
                audioRouter.getDefaultOutputIndex()));
        }
        else if constexpr (std::is_same_v<T, ws::SetAudioInput>)
        {
            auto devices = audioRouter.getDevices();
            for (auto& d : devices) {
                if (d.index == m.deviceIndex && d.isInput) {
                    audioRouter.setInputDevice (d.name);
                    break;
                }
            }
            ws.send (ws::makeAudioStatus (audioRouter.isRunning()));
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
            ws.send (ws::makeAudioStatus (audioRouter.isRunning()));
        }
        else if constexpr (std::is_same_v<T, ws::SetEffectChain>)
        {
            audioRouter.setEffectChain (m.chain);
            ws.send (ws::makeEffectChainSet (m.chain));
        }
        else if constexpr (std::is_same_v<T, ws::StartAudio>)
        {
            bool ok = audioRouter.start();
            ws.send (ws::makeAudioStatus (ok, ok ? "Audio started" : "Failed to start"));
        }
        else if constexpr (std::is_same_v<T, ws::StopAudio>)
        {
            audioRouter.stop();
            ws.send (ws::makeAudioStatus (false, "Audio stopped"));
        }
        else if constexpr (std::is_same_v<T, ws::GetAudioStatus>)
        {
            ws.send (ws::makeAudioStatus (audioRouter.isRunning()));
        }
    }, *msg);
}
