//! strudel-vst-bridge: WebSocket server that hosts AU plugins via AUv3 API with GUI support.

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::net::SocketAddr;
use std::os::raw::c_char;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Instant;

use futures_util::{SinkExt, StreamExt};
use log::{debug, error, info, warn};
use serde::{Deserialize, Serialize};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::Message;

const SAMPLE_RATE: f64 = 48000.0;
const BLOCK_SIZE: u32 = 512;

// ─── FFI to auv3_host.m ────────────────────────────────────────────────────

#[repr(C)]
pub struct AUv3Plugin {
    _opaque: [u8; 0],
}

extern "C" {
    fn auv3_load_plugin(name: *const c_char, sample_rate: f64, max_frames: u32) -> *mut AUv3Plugin;
    fn auv3_destroy_plugin(plugin: *mut AUv3Plugin);
    fn auv3_note_on(plugin: *mut AUv3Plugin, note: u8, velocity: u8, channel: u8) -> i32;
    fn auv3_note_off(plugin: *mut AUv3Plugin, note: u8, velocity: u8, channel: u8) -> i32;
    fn auv3_render(plugin: *mut AUv3Plugin, num_frames: u32, out_left: *mut f32, out_right: *mut f32) -> i32;
    fn auv3_show_gui(plugin: *mut AUv3Plugin);
    fn auv3_parameter_count(plugin: *mut AUv3Plugin) -> u32;
    fn auv3_set_parameter(plugin: *mut AUv3Plugin, index: u32, value: f32) -> i32;
    fn auv3_get_parameter(plugin: *mut AUv3Plugin, index: u32) -> f32;
    fn auv3_get_name(plugin: *mut AUv3Plugin) -> *const c_char;
    fn auv3_run_main_loop();
    fn auv3_show_gui_async(plugin: *mut AUv3Plugin);
    fn auv3_list_plugins(out: *mut AUv3PluginInfoC, max_out: u32) -> u32;
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
    #[serde(rename = "render")]
    Render {
        #[serde(rename = "requestId")]
        request_id: u32,
        #[serde(rename = "pluginId")]
        plugin_id: String,
        note: u8,
        #[serde(default = "default_velocity")]
        velocity: f32,
        #[serde(default = "default_duration")]
        duration: f32,
        #[serde(default)]
        params: HashMap<String, f32>,
    },
    #[serde(rename = "show_gui")]
    ShowGui {
        #[serde(rename = "pluginId")]
        plugin_id: String,
    },
    #[serde(rename = "list_plugins")]
    ListPlugins,
}

fn default_velocity() -> f32 { 0.8 }
fn default_duration() -> f32 { 1.0 }

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

        info!("Instance created: '{}' -> {} ({})", label, name, plugin_name);

        let handle = PluginHandle { ptr, name };
        self.instances.insert(label.to_string(), InstanceInfo {
            plugin_name: plugin_name.to_string(),
            handle: Arc::new(StdMutex::new(handle)),
        });

        Ok(())
    }

    fn delete_instance(&mut self, label: &str) -> bool {
        if self.instances.remove(label).is_some() {
            info!("Instance deleted: '{}'", label);
            true
        } else {
            false
        }
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

// ─── Audio rendering ────────────────────────────────────────────────────────

fn render_note(
    handle: &PluginHandle,
    note: u8,
    velocity: f32,
    duration_secs: f32,
    _params: &HashMap<String, f32>,
) -> Result<(Vec<f32>, Vec<f32>), String> {
    let total_samples = (duration_secs * SAMPLE_RATE as f32) as usize;
    let release_samples = (2.0 * SAMPLE_RATE as f32) as usize;
    let max_samples = total_samples + release_samples;

    let mut left_out = Vec::with_capacity(max_samples);
    let mut right_out = Vec::with_capacity(max_samples);

    let vel_midi = (velocity.clamp(0.0, 1.0) * 127.0) as u8;

    let rc = unsafe { auv3_note_on(handle.ptr, note, vel_midi, 0) };
    if rc != 0 {
        return Err(format!("MIDI note on failed: {rc}"));
    }

    let mut rendered = 0;
    let bs = BLOCK_SIZE as usize;
    let mut lo = vec![0.0f32; bs];
    let mut ro = vec![0.0f32; bs];

    while rendered < total_samples {
        let frames = bs.min(total_samples - rendered);
        lo.iter_mut().for_each(|s| *s = 0.0);
        ro.iter_mut().for_each(|s| *s = 0.0);

        let rc = unsafe { auv3_render(handle.ptr, frames as u32, lo.as_mut_ptr(), ro.as_mut_ptr()) };
        if rc != 0 {
            return Err(format!("Render failed: {rc}"));
        }

        left_out.extend_from_slice(&lo[..frames]);
        right_out.extend_from_slice(&ro[..frames]);
        rendered += frames;
    }

    unsafe { auv3_note_off(handle.ptr, note, 64, 0); }

    let silence_threshold = 1e-6_f32;
    let mut silent_blocks = 0;

    while rendered < max_samples && silent_blocks < 10 {
        let frames = bs.min(max_samples - rendered);
        lo.iter_mut().for_each(|s| *s = 0.0);
        ro.iter_mut().for_each(|s| *s = 0.0);

        let rc = unsafe { auv3_render(handle.ptr, frames as u32, lo.as_mut_ptr(), ro.as_mut_ptr()) };
        if rc != 0 { break; }

        let rms: f32 = lo[..frames].iter().chain(ro[..frames].iter())
            .map(|s| s * s).sum::<f32>() / (frames * 2) as f32;

        if rms < silence_threshold { silent_blocks += 1; } else { silent_blocks = 0; }

        left_out.extend_from_slice(&lo[..frames]);
        right_out.extend_from_slice(&ro[..frames]);
        rendered += frames;
    }

    Ok((left_out, right_out))
}

fn encode_audio_response(request_id: u32, left: &[f32], right: &[f32]) -> Vec<u8> {
    let num_samples = left.len() as u32;
    let mut buf = Vec::with_capacity(8 + (left.len() + right.len()) * 4);
    buf.extend_from_slice(&request_id.to_le_bytes());
    buf.extend_from_slice(&num_samples.to_le_bytes());
    for s in left { buf.extend_from_slice(&s.to_le_bytes()); }
    for s in right { buf.extend_from_slice(&s.to_le_bytes()); }
    buf
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

    let (mut write, mut read) = ws_stream.split();

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
                        let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
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
                                let _ = write.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                            }
                            Err(e) => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: Some(label), request_id: None, message: e };
                                let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
                    }

                    IncomingMessage::DeleteInstance { label } => {
                        let mut mgr = manager.lock().await;
                        mgr.delete_instance(&label);
                        #[derive(Serialize)]
                        struct Msg { #[serde(rename = "type")] msg_type: &'static str, label: String }
                        let msg = Msg { msg_type: "instance_deleted", label };
                        let _ = write.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
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
                        let _ = write.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                    }

                    IncomingMessage::Render { request_id, plugin_id, note, velocity, duration, params } => {
                        let plugin_arc = {
                            let mgr = manager.lock().await;
                            mgr.get_instance(&plugin_id)
                        };

                        match plugin_arc {
                            Some(plugin_mutex) => {
                                let result = tokio::task::spawn_blocking(move || {
                                    let handle = plugin_mutex.lock().unwrap();
                                    render_note(&handle, note, velocity, duration, &params)
                                }).await;

                                match result {
                                    Ok(Ok((left, right))) => {
                                        let binary = encode_audio_response(request_id, &left, &right);
                                        let _ = write.send(Message::Binary(binary)).await;
                                    }
                                    Ok(Err(e)) => {
                                        error!("Render failed: {e}");
                                        let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id), request_id: Some(request_id), message: e };
                                        let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                                    }
                                    Err(e) => {
                                        let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id), request_id: Some(request_id), message: format!("Panic: {e}") };
                                        let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                                    }
                                }
                            }
                            None => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id.clone()), request_id: Some(request_id), message: format!("No instance: {plugin_id}") };
                                let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
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
                                let _ = write.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
                            }
                            None => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id.clone()), request_id: None, message: format!("No instance: {plugin_id}") };
                                let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
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
                        let _ = write.send(Message::Text(serde_json::to_string(&msg).unwrap())).await;
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
