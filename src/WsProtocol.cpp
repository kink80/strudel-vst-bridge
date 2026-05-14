#include "WsProtocol.h"

namespace ws {

std::optional<IncomingMessage> parseMessage (const std::string& jsonStr)
{
    auto json = juce::JSON::parse (jsonStr);
    if (! json.isObject()) return std::nullopt;

    auto* obj = json.getDynamicObject();
    if (! obj) return std::nullopt;
    auto type = obj->getProperty ("type").toString().toStdString();

    if (type == "create_instance")
        return CreateInstance {
            obj->getProperty ("label").toString().toStdString(),
            obj->getProperty ("pluginName").toString().toStdString()
        };
    if (type == "delete_instance")
        return DeleteInstance { obj->getProperty ("label").toString().toStdString() };
    if (type == "list_instances")
        return ListInstances {};
    if (type == "render") {
        Render r;
        r.requestId = (uint32_t)(int)obj->getProperty ("requestId");
        r.pluginId  = obj->getProperty ("pluginId").toString().toStdString();
        r.note      = (uint8_t)(int)obj->getProperty ("note");
        r.velocity  = obj->hasProperty ("velocity") ? (float)obj->getProperty ("velocity") : 0.8f;
        r.duration  = obj->hasProperty ("duration") ? (float)obj->getProperty ("duration") : 1.0f;
        if (auto* p = obj->getProperty ("params").getDynamicObject())
            for (auto& kv : p->getProperties())
                r.params[kv.name.toString().toStdString()] = (float)kv.value;
        return r;
    }
    if (type == "show_gui")
        return ShowGui { obj->getProperty ("pluginId").toString().toStdString() };
    if (type == "list_plugins")
        return ListPlugins {};
    if (type == "list_audio_devices")
        return ListAudioDevices {};
    if (type == "set_audio_input")
        return SetAudioInput { (int)obj->getProperty ("deviceId") };
    if (type == "set_audio_output")
        return SetAudioOutput { (int)obj->getProperty ("deviceId") };
    if (type == "set_effect_chain") {
        SetEffectChain sc;
        if (auto* arr = obj->getProperty ("chain").getArray())
            for (auto& v : *arr)
                sc.chain.push_back (v.toString().toStdString());
        return sc;
    }
    if (type == "start_audio")  return StartAudio {};
    if (type == "stop_audio")   return StopAudio {};
    if (type == "get_audio_status") return GetAudioStatus {};

    return std::nullopt;
}

// ─── JSON helpers ──────────────────────────────────────────────────────────

static std::string toJson (juce::DynamicObject* obj)
{
    return juce::JSON::toString (juce::var (obj), true).toStdString();
}

std::string makePluginList (const std::vector<PluginInfo>& plugins)
{
    auto* obj = new juce::DynamicObject();
    obj->setProperty ("type", "plugin_list");
    juce::Array<juce::var> arr;
    for (auto& p : plugins) {
        auto* e = new juce::DynamicObject();
        e->setProperty ("name", juce::String (p.name));
        e->setProperty ("manufacturer", juce::String (p.manufacturer));
        e->setProperty ("pluginType", juce::String (p.pluginType));
        arr.add (juce::var (e));
    }
    obj->setProperty ("plugins", arr);
    return toJson (obj);
}

std::string makeInstanceList (const std::vector<InstanceInfo>& instances)
{
    auto* obj = new juce::DynamicObject();
    obj->setProperty ("type", "instance_list");
    juce::Array<juce::var> arr;
    for (auto& i : instances) {
        auto* e = new juce::DynamicObject();
        e->setProperty ("label", juce::String (i.label));
        e->setProperty ("pluginName", juce::String (i.pluginName));
        arr.add (juce::var (e));
    }
    obj->setProperty ("instances", arr);
    return toJson (obj);
}

std::string makeInstanceCreated (const std::string& label, const std::string& pluginName)
{
    auto* obj = new juce::DynamicObject();
    obj->setProperty ("type", "instance_created");
    obj->setProperty ("label", juce::String (label));
    obj->setProperty ("pluginName", juce::String (pluginName));
    obj->setProperty ("params", juce::Array<juce::var>());
    return toJson (obj);
}

std::string makeInstanceDeleted (const std::string& label)
{
    auto* obj = new juce::DynamicObject();
    obj->setProperty ("type", "instance_deleted");
    obj->setProperty ("label", juce::String (label));
    return toJson (obj);
}

std::string makeError (const std::string& message, const std::string& pluginId, int requestId)
{
    auto* obj = new juce::DynamicObject();
    obj->setProperty ("type", "error");
    obj->setProperty ("message", juce::String (message));
    if (! pluginId.empty()) obj->setProperty ("pluginId", juce::String (pluginId));
    if (requestId >= 0)     obj->setProperty ("requestId", requestId);
    return toJson (obj);
}

std::string makeGuiOpened (const std::string& pluginId)
{
    auto* obj = new juce::DynamicObject();
    obj->setProperty ("type", "gui_opened");
    obj->setProperty ("pluginId", juce::String (pluginId));
    return toJson (obj);
}

std::string makeAudioDeviceList (const std::vector<AudioDeviceEntry>& devices,
                                  int defaultInput, int defaultOutput)
{
    auto* obj = new juce::DynamicObject();
    obj->setProperty ("type", "audio_device_list");
    juce::Array<juce::var> arr;
    for (auto& d : devices) {
        auto* e = new juce::DynamicObject();
        e->setProperty ("deviceId", d.index);
        e->setProperty ("name", juce::String (d.name));
        e->setProperty ("isInput", d.isInput);
        e->setProperty ("isOutput", d.isOutput);
        e->setProperty ("inputChannels", d.inputChannels);
        e->setProperty ("outputChannels", d.outputChannels);
        arr.add (juce::var (e));
    }
    obj->setProperty ("devices", arr);
    obj->setProperty ("defaultInput", defaultInput);
    obj->setProperty ("defaultOutput", defaultOutput);
    return toJson (obj);
}

std::string makeAudioStatus (bool running, const std::string& message)
{
    auto* obj = new juce::DynamicObject();
    obj->setProperty ("type", "audio_status");
    obj->setProperty ("running", running);
    if (! message.empty()) obj->setProperty ("message", juce::String (message));
    return toJson (obj);
}

std::string makeEffectChainSet (const std::vector<std::string>& chain)
{
    auto* obj = new juce::DynamicObject();
    obj->setProperty ("type", "effect_chain_set");
    juce::Array<juce::var> arr;
    for (auto& l : chain) arr.add (juce::String (l));
    obj->setProperty ("chain", arr);
    return toJson (obj);
}

std::string makeDeviceListChanged()
{
    return R"({"type":"device_list_changed"})";
}

std::vector<uint8_t> encodeAudioResponse (uint32_t requestId,
                                           const float* left, const float* right,
                                           uint32_t numSamples)
{
    size_t totalBytes = 8 + (size_t)numSamples * 2 * sizeof (float);
    std::vector<uint8_t> buf (totalBytes);
    memcpy (buf.data(), &requestId, 4);
    memcpy (buf.data() + 4, &numSamples, 4);
    memcpy (buf.data() + 8, left, numSamples * sizeof (float));
    memcpy (buf.data() + 8 + numSamples * sizeof (float), right, numSamples * sizeof (float));
    return buf;
}

} // namespace ws
