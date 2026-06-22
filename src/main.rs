//! strudel-vst-bridge: WebSocket server that hosts AU plugins via AUv3 API with GUI support.

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::net::SocketAddr;
use std::os::raw::c_char;
use std::sync::{Arc, Mutex as StdMutex};

use std::path::PathBuf;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use futures_util::{SinkExt, StreamExt};
use log::{error, info, warn};
use serde::{Deserialize, Serialize};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::Message;

const SAMPLE_RATE: f64 = 48000.0;
const BLOCK_SIZE: u32 = 2048;

// ─── FFI to auv3_host.m ────────────────────────────────────────────────────

#[repr(C)]
pub struct AUv3Plugin {
    _opaque: [u8; 0],
}

extern "C" {
    fn auv3_load_plugin(name: *const c_char, sample_rate: f64, max_frames: u32) -> *mut AUv3Plugin;
    fn auv3_destroy_plugin(plugin: *mut AUv3Plugin);
    fn auv3_engine_attach(plugin: *mut AUv3Plugin) -> i32;
    fn auv3_create_midi_source(plugin: *mut AUv3Plugin, label: *const c_char) -> i32;
    fn auv3_show_gui(plugin: *mut AUv3Plugin);
    fn auv3_get_name(plugin: *mut AUv3Plugin) -> *const c_char;
    fn auv3_run_main_loop();
    fn auv3_show_gui_async(plugin: *mut AUv3Plugin);
    fn auv3_list_plugins(out: *mut AUv3PluginInfoC, max_out: u32) -> u32;
    fn auv3_get_state(plugin: *mut AUv3Plugin, out_len: *mut u32) -> *mut u8;
    fn auv3_set_state(plugin: *mut AUv3Plugin, bytes: *const u8, len: u32) -> i32;
    fn free(ptr: *mut u8);
}

#[repr(C)]
#[derive(Clone)]
struct AUv3PluginInfoC {
    name: [u8; 256],
    manufacturer: [u8; 256],
    plugin_type: [u8; 32],
}

fn c_str(buf: &[u8]) -> String {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).to_string()
}

unsafe impl Send for PluginHandle {}

struct PluginHandle {
    ptr: *mut AUv3Plugin,
    name: String,
}

impl Drop for PluginHandle {
    fn drop(&mut self) {
        unsafe { auv3_destroy_plugin(self.ptr); }
    }
}

// ─── Protocol types ─────────────────────────────────────────────────────────

#[derive(Deserialize, Debug)]
#[serde(tag = "type")]
enum IncomingMessage {
    #[serde(rename = "create_instance")]
    CreateInstance {
        label: String,
        #[serde(rename = "pluginName")]
        plugin_name: String,
    },
    #[serde(rename = "delete_instance")]
    DeleteInstance {
        label: String,
    },
    #[serde(rename = "list_instances")]
    ListInstances,
    #[serde(rename = "show_gui")]
    ShowGui {
        #[serde(rename = "pluginId")]
        plugin_id: String,
    },
    #[serde(rename = "list_plugins")]
    ListPlugins,
    #[serde(rename = "get_state")]
    GetState {
        #[serde(rename = "requestId")]
        request_id: u32,
        #[serde(rename = "pluginId")]
        plugin_id: String,
    },
    #[serde(rename = "set_state")]
    SetState {
        #[serde(rename = "requestId")]
        request_id: u32,
        #[serde(rename = "pluginId")]
        plugin_id: String,
        /// Base64-encoded NSKeyedArchiver blob.
        state: String,
    },
    #[serde(rename = "save_preset")]
    SavePreset {
        #[serde(rename = "requestId")]
        request_id: u32,
        #[serde(rename = "pluginName")]
        plugin_name: String,
        #[serde(rename = "presetName")]
        preset_name: String,
        /// Free-form JSON document chosen by the client.
        data: serde_json::Value,
    },
    #[serde(rename = "load_preset")]
    LoadPreset {
        #[serde(rename = "requestId")]
        request_id: u32,
        #[serde(rename = "pluginName")]
        plugin_name: String,
        #[serde(rename = "presetName")]
        preset_name: String,
    },
    #[serde(rename = "list_presets")]
    ListPresets {
        #[serde(rename = "requestId")]
        request_id: u32,
        #[serde(rename = "pluginName")]
        plugin_name: String,
    },
    #[serde(rename = "delete_preset")]
    DeletePreset {
        #[serde(rename = "requestId")]
        request_id: u32,
        #[serde(rename = "pluginName")]
        plugin_name: String,
        #[serde(rename = "presetName")]
        preset_name: String,
    },
}

#[derive(Serialize)]
struct ErrorMsg {
    #[serde(rename = "type")]
    msg_type: &'static str,
    #[serde(rename = "pluginId")]
    plugin_id: Option<String>,
    #[serde(rename = "requestId")]
    request_id: Option<u32>,
    message: String,
}

#[derive(Serialize)]
struct GuiOpenedMsg {
    #[serde(rename = "type")]
    msg_type: &'static str,
    #[serde(rename = "pluginId")]
    plugin_id: String,
}

// ─── Plugin manager with instance registry ─────────────────────────────────

struct InstanceInfo {
    plugin_name: String,
    handle: Arc<StdMutex<PluginHandle>>,
}

struct PluginManager {
    // label -> instance (plugin handle + metadata)
    instances: HashMap<String, InstanceInfo>,
}

impl PluginManager {
    fn new() -> Self {
        Self { instances: HashMap::new() }
    }

    fn create_instance(&mut self, label: &str, plugin_name: &str) -> Result<(), String> {
        if self.instances.contains_key(label) {
            return Err(format!("Instance '{}' already exists", label));
        }

        let c_name = CString::new(plugin_name).map_err(|e| format!("Invalid name: {e}"))?;
        let ptr = unsafe { auv3_load_plugin(c_name.as_ptr(), SAMPLE_RATE, BLOCK_SIZE) };
        if ptr.is_null() {
            return Err(format!("Failed to load plugin: {plugin_name}"));
        }

        let name = unsafe {
            let cstr = auv3_get_name(ptr);
            CStr::from_ptr(cstr).to_string_lossy().to_string()
        };

        // Wire into the realtime audio engine and expose a virtual MIDI port.
        // If either fails the instance is still registered — params/state/GUI
        // still work — but it won't be audible / drivable. Caller sees logs.
        let rc = unsafe { auv3_engine_attach(ptr) };
        if rc != 0 { warn!("engine_attach({label}) returned {rc}"); }
        let c_label = CString::new(label).map_err(|e| format!("Invalid label: {e}"))?;
        let rc = unsafe { auv3_create_midi_source(ptr, c_label.as_ptr()) };
        if rc != 0 { warn!("create_midi_source({label}) returned {rc}"); }

        info!("Instance created: '{}' -> {} ({})", label, name, plugin_name);

        let handle = PluginHandle { ptr, name };
        self.instances.insert(label.to_string(), InstanceInfo {
            plugin_name: plugin_name.to_string(),
            handle: Arc::new(StdMutex::new(handle)),
        });

        Ok(())
    }

    /// Remove an instance from the registry, returning the handle for deferred destruction.
    fn delete_instance(&mut self, label: &str) -> Option<InstanceInfo> {
        let removed = self.instances.remove(label);
        if removed.is_some() {
            info!("Instance removed from registry: '{}'", label);
        }
        removed
    }

    fn get_instance(&self, label: &str) -> Option<Arc<StdMutex<PluginHandle>>> {
        self.instances.get(label).map(|i| i.handle.clone())
    }

    fn list_instances(&self) -> Vec<(String, String)> {
        self.instances.iter()
            .map(|(label, info)| (label.clone(), info.plugin_name.clone()))
            .collect()
    }
}

// ─── Preset file storage ────────────────────────────────────────────────────
// Layout: ~/.strudel-vst-bridge/presets/<plugin>/<preset>.json
// Names are sanitized to filesystem-safe characters to keep this dumb.

fn sanitize(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == ' ' { c } else { '_' })
        .collect()
}

fn presets_root() -> Option<PathBuf> {
    // Store next to the bridge binary's source tree: <bridge-dir>/presets/
    // Resolved from CARGO_MANIFEST_DIR at compile time so it works regardless
    // of where the binary is launched from.
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("presets");
    Some(p)
}

fn preset_dir(plugin_name: &str) -> Option<PathBuf> {
    let mut p = presets_root()?;
    p.push(sanitize(plugin_name));
    Some(p)
}

fn preset_path(plugin_name: &str, preset_name: &str) -> Option<PathBuf> {
    let mut p = preset_dir(plugin_name)?;
    p.push(format!("{}.json", sanitize(preset_name)));
    Some(p)
}

fn save_preset_file(plugin_name: &str, preset_name: &str, data: &serde_json::Value) -> Result<(), String> {
    let dir = preset_dir(plugin_name).ok_or("HOME not set")?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("mkdir: {e}"))?;
    let path = preset_path(plugin_name, preset_name).ok_or("HOME not set")?;
    let serialized = serde_json::to_string_pretty(data).map_err(|e| format!("serialize: {e}"))?;
    std::fs::write(&path, serialized).map_err(|e| format!("write {}: {e}", path.display()))
}

fn load_preset_file(plugin_name: &str, preset_name: &str) -> Result<serde_json::Value, String> {
    let path = preset_path(plugin_name, preset_name).ok_or("HOME not set")?;
    let raw = std::fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
    serde_json::from_str(&raw).map_err(|e| format!("parse {}: {e}", path.display()))
}

fn list_preset_files(plugin_name: &str) -> Result<Vec<String>, String> {
    let dir = match preset_dir(plugin_name) {
        Some(d) => d,
        None => return Ok(vec![]),
    };
    if !dir.exists() {
        return Ok(vec![]);
    }
    let mut out = vec![];
    for entry in std::fs::read_dir(&dir).map_err(|e| format!("readdir {}: {e}", dir.display()))? {
        let entry = entry.map_err(|e| format!("entry: {e}"))?;
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) == Some("json") {
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                out.push(stem.to_string());
            }
        }
    }
    out.sort();
    Ok(out)
}

fn delete_preset_file(plugin_name: &str, preset_name: &str) -> Result<(), String> {
    let path = preset_path(plugin_name, preset_name).ok_or("HOME not set")?;
    if !path.exists() {
        return Err(format!("no such preset: {}", path.display()));
    }
    std::fs::remove_file(&path).map_err(|e| format!("remove: {e}"))
}

// ─── WebSocket server ───────────────────────────────────────────────────────

async fn handle_connection(
    stream: TcpStream,
    addr: SocketAddr,
    manager: Arc<Mutex<PluginManager>>,
) {
    info!("New connection from {addr}");

    let ws_stream = match tokio_tungstenite::accept_async(stream).await {
        Ok(ws) => ws,
        Err(e) => { error!("WebSocket handshake failed: {e}"); return; }
    };

    let (write, mut read) = ws_stream.split();
    // Wrap writer in Arc<Mutex> so render tasks can send responses concurrently
    let write = Arc::new(Mutex::new(write));

    while let Some(msg) = read.next().await {
        let msg = match msg {
            Ok(m) => m,
            Err(e) => { warn!("Read error: {e}"); break; }
        };

        match msg {
            Message::Text(text) => {
                let incoming: IncomingMessage = match serde_json::from_str(&text) {
                    Ok(m) => m,
                    Err(e) => {
                        let err = ErrorMsg { msg_type: "error", plugin_id: None, request_id: None, message: format!("Invalid: {e}") };
                        let mut w = write.lock().await;
                        let _ = w.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                        continue;
                    }
                };

                match incoming {
                    IncomingMessage::CreateInstance { label, plugin_name } => {
                        let mut mgr = manager.lock().await;
                        match mgr.create_instance(&label, &plugin_name) {
                            Ok(()) => {
                                #[derive(Serialize)]
                                struct Msg { #[serde(rename = "type")] msg_type: &'static str, label: String, #[serde(rename = "pluginName")] plugin_name: String, params: Vec<()> }
                                let msg = Msg { msg_type: "instance_created", label, plugin_name, params: vec![] };
                                let mut w = write.lock().await;
                                let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                            }
                            Err(e) => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: Some(label), request_id: None, message: e };
                                let mut w = write.lock().await;
                                let _ = w.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
                    }

                    IncomingMessage::DeleteInstance { label } => {
                        // Remove from registry under lock, then drop handle outside
                        let removed = {
                            let mut mgr = manager.lock().await;
                            mgr.delete_instance(&label)
                        };
                        // Send response before destroying plugin (which may block)
                        #[derive(Serialize)]
                        struct Msg { #[serde(rename = "type")] msg_type: &'static str, label: String }
                        let msg = Msg { msg_type: "instance_deleted", label };
                        let mut w = write.lock().await;
                        let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                        // Plugin handle drops here — auv3_destroy_plugin runs outside the lock
                        drop(removed);
                    }

                    IncomingMessage::ListInstances => {
                        let mgr = manager.lock().await;
                        let instances = mgr.list_instances();
                        #[derive(Serialize)]
                        struct Msg { #[serde(rename = "type")] msg_type: &'static str, instances: Vec<InstanceEntry> }
                        #[derive(Serialize)]
                        struct InstanceEntry { label: String, #[serde(rename = "pluginName")] plugin_name: String }
                        let msg = Msg {
                            msg_type: "instance_list",
                            instances: instances.into_iter().map(|(label, plugin_name)| InstanceEntry { label, plugin_name }).collect(),
                        };
                        let mut w = write.lock().await;
                        let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                    }

                    IncomingMessage::ShowGui { plugin_id } => {
                        let plugin_arc = {
                            let mgr = manager.lock().await;
                            mgr.get_instance(&plugin_id)
                        };
                        match plugin_arc {
                            Some(plugin) => {
                                info!("Opening GUI for: {plugin_id}");
                                {
                                    let handle = plugin.lock().unwrap();
                                    unsafe { auv3_show_gui_async(handle.ptr); }
                                }
                                let msg = GuiOpenedMsg { msg_type: "gui_opened", plugin_id };
                                let mut w = write.lock().await;
                                let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                            }
                            None => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id.clone()), request_id: None, message: format!("No instance: {plugin_id}") };
                                let mut w = write.lock().await;
                                let _ = w.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
                    }

                    IncomingMessage::ListPlugins => {
                        let mut infos = vec![AUv3PluginInfoC {
                            name: [0u8; 256],
                            manufacturer: [0u8; 256],
                            plugin_type: [0u8; 32],
                        }; 512];
                        let count = unsafe { auv3_list_plugins(infos.as_mut_ptr(), 512) } as usize;

                        #[derive(Serialize)]
                        struct ListMsg {
                            #[serde(rename = "type")]
                            msg_type: &'static str,
                            plugins: Vec<PluginEntry>,
                        }
                        #[derive(Serialize)]
                        struct PluginEntry {
                            name: String,
                            manufacturer: String,
                            #[serde(rename = "pluginType")]
                            plugin_type: String,
                        }

                        let plugins: Vec<PluginEntry> = infos[..count].iter().map(|i| PluginEntry {
                            name: c_str(&i.name),
                            manufacturer: c_str(&i.manufacturer),
                            plugin_type: c_str(&i.plugin_type),
                        }).collect();

                        let msg = ListMsg { msg_type: "plugin_list", plugins };
                        let mut w = write.lock().await;
                        let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                    }

                    IncomingMessage::GetState { request_id, plugin_id } => {
                        let plugin_arc = {
                            let mgr = manager.lock().await;
                            mgr.get_instance(&plugin_id)
                        };
                        let result: Result<String, String> = match plugin_arc {
                            Some(p) => {
                                let handle = p.lock().unwrap();
                                let mut len: u32 = 0;
                                let buf = unsafe { auv3_get_state(handle.ptr, &mut len as *mut u32) };
                                if buf.is_null() || len == 0 {
                                    Err("get_state failed".into())
                                } else {
                                    let slice = unsafe { std::slice::from_raw_parts(buf, len as usize) };
                                    let encoded = B64.encode(slice);
                                    unsafe { free(buf); }
                                    Ok(encoded)
                                }
                            }
                            None => Err(format!("No instance: {plugin_id}")),
                        };
                        let mut w = write.lock().await;
                        match result {
                            Ok(encoded) => {
                                #[derive(Serialize)]
                                struct Msg { #[serde(rename = "type")] msg_type: &'static str, #[serde(rename = "requestId")] request_id: u32, #[serde(rename = "pluginId")] plugin_id: String, state: String }
                                let msg = Msg { msg_type: "state", request_id, plugin_id, state: encoded };
                                let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                            }
                            Err(message) => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id), request_id: Some(request_id), message };
                                let _ = w.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
                    }

                    IncomingMessage::SavePreset { request_id, plugin_name, preset_name, data } => {
                        let mut w = write.lock().await;
                        match save_preset_file(&plugin_name, &preset_name, &data) {
                            Ok(()) => {
                                #[derive(Serialize)]
                                struct Msg { #[serde(rename = "type")] msg_type: &'static str, #[serde(rename = "requestId")] request_id: u32, #[serde(rename = "pluginName")] plugin_name: String, #[serde(rename = "presetName")] preset_name: String }
                                let msg = Msg { msg_type: "preset_saved", request_id, plugin_name, preset_name };
                                let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                            }
                            Err(e) => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: None, request_id: Some(request_id), message: e };
                                let _ = w.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
                    }

                    IncomingMessage::LoadPreset { request_id, plugin_name, preset_name } => {
                        let mut w = write.lock().await;
                        match load_preset_file(&plugin_name, &preset_name) {
                            Ok(data) => {
                                #[derive(Serialize)]
                                struct Msg { #[serde(rename = "type")] msg_type: &'static str, #[serde(rename = "requestId")] request_id: u32, #[serde(rename = "pluginName")] plugin_name: String, #[serde(rename = "presetName")] preset_name: String, data: serde_json::Value }
                                let msg = Msg { msg_type: "preset", request_id, plugin_name, preset_name, data };
                                let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                            }
                            Err(e) => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: None, request_id: Some(request_id), message: e };
                                let _ = w.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
                    }

                    IncomingMessage::ListPresets { request_id, plugin_name } => {
                        let mut w = write.lock().await;
                        match list_preset_files(&plugin_name) {
                            Ok(names) => {
                                #[derive(Serialize)]
                                struct Msg { #[serde(rename = "type")] msg_type: &'static str, #[serde(rename = "requestId")] request_id: u32, #[serde(rename = "pluginName")] plugin_name: String, presets: Vec<String> }
                                let msg = Msg { msg_type: "preset_list", request_id, plugin_name, presets: names };
                                let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                            }
                            Err(e) => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: None, request_id: Some(request_id), message: e };
                                let _ = w.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
                    }

                    IncomingMessage::DeletePreset { request_id, plugin_name, preset_name } => {
                        let mut w = write.lock().await;
                        match delete_preset_file(&plugin_name, &preset_name) {
                            Ok(()) => {
                                #[derive(Serialize)]
                                struct Msg { #[serde(rename = "type")] msg_type: &'static str, #[serde(rename = "requestId")] request_id: u32, #[serde(rename = "pluginName")] plugin_name: String, #[serde(rename = "presetName")] preset_name: String }
                                let msg = Msg { msg_type: "preset_deleted", request_id, plugin_name, preset_name };
                                let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                            }
                            Err(e) => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: None, request_id: Some(request_id), message: e };
                                let _ = w.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
                    }

                    IncomingMessage::SetState { request_id, plugin_id, state } => {
                        let plugin_arc = {
                            let mgr = manager.lock().await;
                            mgr.get_instance(&plugin_id)
                        };
                        let result: Result<(), String> = match plugin_arc {
                            Some(p) => match B64.decode(state.as_bytes()) {
                                Ok(bytes) => {
                                    let handle = p.lock().unwrap();
                                    let rc = unsafe { auv3_set_state(handle.ptr, bytes.as_ptr(), bytes.len() as u32) };
                                    if rc == 0 { Ok(()) } else { Err(format!("set_state failed: {rc}")) }
                                }
                                Err(e) => Err(format!("base64 decode: {e}")),
                            },
                            None => Err(format!("No instance: {plugin_id}")),
                        };
                        let mut w = write.lock().await;
                        match result {
                            Ok(()) => {
                                #[derive(Serialize)]
                                struct Msg { #[serde(rename = "type")] msg_type: &'static str, #[serde(rename = "requestId")] request_id: u32, #[serde(rename = "pluginId")] plugin_id: String }
                                let msg = Msg { msg_type: "state_loaded", request_id, plugin_id };
                                let _ = w.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                            }
                            Err(message) => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id), request_id: Some(request_id), message };
                                let _ = w.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
                    }
                }
            }
            Message::Close(_) => { info!("Connection closed: {addr}"); break; }
            _ => {}
        }
    }
}

// ─── Main ───────────────────────────────────────────────────────────────────

fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let addr = "127.0.0.1:8765";

    let manager = Arc::new(Mutex::new(PluginManager::new()));

    let manager_clone = manager.clone();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async move {
            let listener = TcpListener::bind(addr).await.unwrap();
            info!("strudel-vst-bridge listening on ws://{addr} (AUv3 backend)");
            info!("Create instances in the VST panel, then use: note(\"c3 e3\").vst(\"label\")");

            loop {
                let (stream, addr) = listener.accept().await.unwrap();
                let manager = manager_clone.clone();
                tokio::spawn(handle_connection(stream, addr, manager));
            }
        });
    });

    info!("Main thread running NSApp event loop for GUI support");
    unsafe { auv3_run_main_loop(); }

    Ok(())
}
