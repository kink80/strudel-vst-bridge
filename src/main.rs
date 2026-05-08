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

use rack::vst3::{Vst3Scanner, Vst3Plugin};
use rack::{MidiEvent, PluginInstance, PluginScanner, PluginInfo as RackPluginInfo, PluginType as RackPluginType};

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

struct Vst3PluginHandle {
    plugin: Vst3Plugin,
    name: String,
}

unsafe impl Send for Vst3PluginHandle {}

fn parse_plugin_format(plugin_id: &str) -> (&str, &str) {
    if let Some(name) = plugin_id.strip_suffix(" (VST3)") {
        (name, "vst3")
    } else if let Some(name) = plugin_id.strip_suffix(" (AU)") {
        (name, "au")
    } else {
        (plugin_id, "au") // default to AU for backwards compatibility
    }
}

// macOS event loop handled by auv3_pump_events() in auv3_host.m

// ─── Protocol types ─────────────────────────────────────────────────────────

#[derive(Deserialize, Debug)]
#[serde(tag = "type")]
enum IncomingMessage {
    #[serde(rename = "load_plugin")]
    LoadPlugin {
        #[serde(rename = "pluginId")]
        plugin_id: String,
        path: Option<String>,
    },
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
struct PluginLoadedMsg {
    #[serde(rename = "type")]
    msg_type: &'static str,
    #[serde(rename = "pluginId")]
    plugin_id: String,
    name: String,
    params: Vec<ParamInfoMsg>,
}

#[derive(Serialize)]
struct ParamInfoMsg {
    index: usize,
    name: String,
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

// ─── Plugin manager ─────────────────────────────────────────────────────────

struct PluginManager {
    au_plugins: HashMap<String, Arc<StdMutex<PluginHandle>>>,
    vst3_plugins: HashMap<String, Arc<StdMutex<Vst3PluginHandle>>>,
    vst3_scanner: Option<Vst3Scanner>,
    vst3_catalog: Vec<RackPluginInfo>,
}

impl PluginManager {
    fn new() -> Self {
        // Initialize VST3 scanner, log warning if it fails
        let (vst3_scanner, vst3_catalog) = match Vst3Scanner::new() {
            Ok(scanner) => {
                let catalog = match scanner.scan() {
                    Ok(plugins) => {
                        info!("Found {} VST3 plugins", plugins.len());
                        plugins
                    }
                    Err(e) => {
                        warn!("VST3 scan failed: {e}");
                        Vec::new()
                    }
                };
                (Some(scanner), catalog)
            }
            Err(e) => {
                warn!("VST3 scanner init failed: {e}");
                (None, Vec::new())
            }
        };

        Self {
            au_plugins: HashMap::new(),
            vst3_plugins: HashMap::new(),
            vst3_scanner,
            vst3_catalog,
        }
    }

    fn load_plugin(&mut self, plugin_id: &str) -> Result<PluginLoadedMsg, String> {
        let (name, format) = parse_plugin_format(plugin_id);

        match format {
            "vst3" => self.load_vst3_plugin(plugin_id, name),
            _ => self.load_au_plugin(plugin_id, name),
        }
    }

    fn load_au_plugin(&mut self, plugin_id: &str, name: &str) -> Result<PluginLoadedMsg, String> {
        if self.au_plugins.contains_key(plugin_id) {
            let handle = self.au_plugins.get(plugin_id).unwrap().lock().unwrap();
            return Ok(PluginLoadedMsg {
                msg_type: "plugin_loaded",
                plugin_id: plugin_id.to_string(),
                name: handle.name.clone(),
                params: vec![],
            });
        }

        let c_name = CString::new(name).map_err(|e| format!("Invalid name: {e}"))?;
        let ptr = unsafe { auv3_load_plugin(c_name.as_ptr(), SAMPLE_RATE, BLOCK_SIZE) };
        if ptr.is_null() {
            return Err(format!("Failed to load AU plugin: {name}"));
        }

        let actual_name = unsafe {
            let cstr = auv3_get_name(ptr);
            CStr::from_ptr(cstr).to_string_lossy().to_string()
        };

        info!("Plugin loaded: {} (via AUv3)", actual_name);

        let handle = PluginHandle { ptr, name: actual_name.clone() };
        self.au_plugins.insert(plugin_id.to_string(), Arc::new(StdMutex::new(handle)));

        Ok(PluginLoadedMsg {
            msg_type: "plugin_loaded",
            plugin_id: plugin_id.to_string(),
            name: actual_name,
            params: vec![],
        })
    }

    fn load_vst3_plugin(&mut self, plugin_id: &str, name: &str) -> Result<PluginLoadedMsg, String> {
        if self.vst3_plugins.contains_key(plugin_id) {
            let handle = self.vst3_plugins.get(plugin_id).unwrap().lock().unwrap();
            return Ok(PluginLoadedMsg {
                msg_type: "plugin_loaded",
                plugin_id: plugin_id.to_string(),
                name: handle.name.clone(),
                params: vec![],
            });
        }

        let scanner = self.vst3_scanner.as_ref()
            .ok_or_else(|| "VST3 scanner not available".to_string())?;

        let info = self.vst3_catalog.iter()
            .find(|p| p.name == name)
            .ok_or_else(|| format!("VST3 plugin not found: {name}"))?
            .clone();

        let mut plugin = scanner.load(&info)
            .map_err(|e| format!("Failed to load VST3 plugin {name}: {e}"))?;

        plugin.initialize(SAMPLE_RATE, BLOCK_SIZE as usize)
            .map_err(|e| format!("Failed to initialize VST3 plugin {name}: {e}"))?;

        info!("Plugin loaded: {} (via VST3)", name);

        let handle = Vst3PluginHandle {
            plugin,
            name: name.to_string(),
        };
        self.vst3_plugins.insert(plugin_id.to_string(), Arc::new(StdMutex::new(handle)));

        Ok(PluginLoadedMsg {
            msg_type: "plugin_loaded",
            plugin_id: plugin_id.to_string(),
            name: name.to_string(),
            params: vec![],
        })
    }

    fn get_au_plugin(&self, plugin_id: &str) -> Option<Arc<StdMutex<PluginHandle>>> {
        self.au_plugins.get(plugin_id).cloned()
    }

    fn get_vst3_plugin(&self, plugin_id: &str) -> Option<Arc<StdMutex<Vst3PluginHandle>>> {
        self.vst3_plugins.get(plugin_id).cloned()
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

    // Note on
    let rc = unsafe { auv3_note_on(handle.ptr, note, vel_midi, 0) };
    if rc != 0 {
        return Err(format!("MIDI note on failed: {rc}"));
    }

    // Render note-on duration
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

    // Note off
    unsafe { auv3_note_off(handle.ptr, note, 64, 0); }

    // Render release tail
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

fn render_note_vst3(
    handle: &mut Vst3PluginHandle,
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
    let bs = BLOCK_SIZE as usize;

    // Note on
    handle.plugin.send_midi(&[MidiEvent::note_on(note, vel_midi, 0, 0)])
        .map_err(|e| format!("MIDI note on failed: {e}"))?;

    // Render note-on duration
    let mut rendered = 0;
    let mut lo = vec![0.0f32; bs];
    let mut ro = vec![0.0f32; bs];

    while rendered < total_samples {
        let frames = bs.min(total_samples - rendered);
        lo.iter_mut().for_each(|s| *s = 0.0);
        ro.iter_mut().for_each(|s| *s = 0.0);

        {
            let mut outputs: [&mut [f32]; 2] = [&mut lo[..frames], &mut ro[..frames]];
            handle.plugin.process(&[], &mut outputs, frames)
                .map_err(|e| format!("Render failed: {e}"))?;
        }

        left_out.extend_from_slice(&lo[..frames]);
        right_out.extend_from_slice(&ro[..frames]);
        rendered += frames;
    }

    // Note off
    handle.plugin.send_midi(&[MidiEvent::note_off(note, 64, 0, 0)])
        .map_err(|e| format!("MIDI note off failed: {e}"))?;

    // Render release tail
    let silence_threshold = 1e-6_f32;
    let mut silent_blocks = 0;

    while rendered < max_samples && silent_blocks < 10 {
        let frames = bs.min(max_samples - rendered);
        lo.iter_mut().for_each(|s| *s = 0.0);
        ro.iter_mut().for_each(|s| *s = 0.0);

        {
            let mut outputs: [&mut [f32]; 2] = [&mut lo[..frames], &mut ro[..frames]];
            if handle.plugin.process(&[], &mut outputs, frames).is_err() {
                break;
            }
        }

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

// GUI requests are now dispatched directly via auv3_show_gui_async (uses dispatch_async to main queue)

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
                    IncomingMessage::LoadPlugin { plugin_id, .. } => {
                        let mut mgr = manager.lock().await;
                        match mgr.load_plugin(&plugin_id) {
                            Ok(msg) => { let _ = write.send(Message::Text(serde_json::to_string(&msg).unwrap())).await; }
                            Err(e) => {
                                let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id), request_id: None, message: e };
                                let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                        }
                    }

                    IncomingMessage::Render { request_id, plugin_id, note, velocity, duration, params } => {
                        let (_, format) = parse_plugin_format(&plugin_id);
                        let format = format.to_string();

                        // Auto-load plugin on first render if not loaded
                        {
                            let mut mgr = manager.lock().await;
                            let needs_load = match format.as_str() {
                                "vst3" => mgr.get_vst3_plugin(&plugin_id).is_none(),
                                _ => mgr.get_au_plugin(&plugin_id).is_none(),
                            };
                            if needs_load {
                                info!("Auto-loading plugin for render: {plugin_id}");
                                if let Err(e) = mgr.load_plugin(&plugin_id) {
                                    let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id), request_id: Some(request_id), message: e };
                                    let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                                    continue;
                                }
                            }
                        }

                        let result = match format.as_str() {
                            "vst3" => {
                                let plugin_arc = {
                                    let mgr = manager.lock().await;
                                    mgr.get_vst3_plugin(&plugin_id)
                                };
                                match plugin_arc {
                                    Some(plugin_mutex) => {
                                        tokio::task::spawn_blocking(move || {
                                            let mut handle = plugin_mutex.lock().unwrap();
                                            render_note_vst3(&mut handle, note, velocity, duration, &params)
                                        }).await
                                    }
                                    None => {
                                        let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id.clone()), request_id: Some(request_id), message: format!("Failed to load: {plugin_id}") };
                                        let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                                        continue;
                                    }
                                }
                            }
                            _ => {
                                let plugin_arc = {
                                    let mgr = manager.lock().await;
                                    mgr.get_au_plugin(&plugin_id)
                                };
                                match plugin_arc {
                                    Some(plugin_mutex) => {
                                        tokio::task::spawn_blocking(move || {
                                            let handle = plugin_mutex.lock().unwrap();
                                            render_note(&handle, note, velocity, duration, &params)
                                        }).await
                                    }
                                    None => {
                                        let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id.clone()), request_id: Some(request_id), message: format!("Failed to load: {plugin_id}") };
                                        let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                                        continue;
                                    }
                                }
                            }
                        };

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

                    IncomingMessage::ShowGui { plugin_id } => {
                        let (_, format) = parse_plugin_format(&plugin_id);
                        let format = format.to_string();

                        // Auto-load plugin if not loaded
                        {
                            let mut mgr = manager.lock().await;
                            let needs_load = match format.as_str() {
                                "vst3" => mgr.get_vst3_plugin(&plugin_id).is_none(),
                                _ => mgr.get_au_plugin(&plugin_id).is_none(),
                            };
                            if needs_load {
                                info!("Auto-loading plugin for GUI: {plugin_id}");
                                let _ = mgr.load_plugin(&plugin_id);
                            }
                        }

                        match format.as_str() {
                            "vst3" => {
                                // VST3 GUI not yet implemented in rack
                                let err = ErrorMsg {
                                    msg_type: "error",
                                    plugin_id: Some(plugin_id),
                                    request_id: None,
                                    message: "VST3 GUI not yet supported".to_string(),
                                };
                                let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                            }
                            _ => {
                                let mgr = manager.lock().await;
                                match mgr.get_au_plugin(&plugin_id) {
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
                                        let err = ErrorMsg { msg_type: "error", plugin_id: Some(plugin_id.clone()), request_id: None, message: format!("Failed to load: {plugin_id}") };
                                        let _ = write.send(Message::Text(serde_json::to_string(&err).unwrap())).await;
                                    }
                                }
                            }
                        }
                    }

                    IncomingMessage::ListPlugins => {
                        // AU plugins
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
                            format: String,
                        }

                        let mut plugins: Vec<PluginEntry> = infos[..count].iter().map(|i| PluginEntry {
                            name: format!("{} (AU)", c_str(&i.name)),
                            manufacturer: c_str(&i.manufacturer),
                            plugin_type: c_str(&i.plugin_type),
                            format: "au".to_string(),
                        }).collect();

                        // VST3 plugins
                        let mgr = manager.lock().await;
                        for info in &mgr.vst3_catalog {
                            let plugin_type = match info.plugin_type {
                                RackPluginType::Instrument => "Instrument",
                                RackPluginType::Effect => "Effect",
                                _ => "Other",
                            };
                            plugins.push(PluginEntry {
                                name: format!("{} (VST3)", info.name),
                                manufacturer: info.manufacturer.clone(),
                                plugin_type: plugin_type.to_string(),
                                format: "vst3".to_string(),
                            });
                        }

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

    // Spawn tokio on background thread
    let manager_clone = manager.clone();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async move {
            let listener = TcpListener::bind(addr).await.unwrap();
            info!("strudel-vst-bridge listening on ws://{addr} (AU + VST3 backends)");
            info!("Usage: note(\"c3 e3 g3\").vst(\"Odin2\")");
            info!("GUI:   vstGui(\"Odin2\")");

            loop {
                let (stream, addr) = listener.accept().await.unwrap();
                let manager = manager_clone.clone();
                tokio::spawn(handle_connection(stream, addr, manager));
            }
        });
    });

    // Main thread: run macOS NSApp event loop (never returns)
    // This is required for JUCE plugin GUIs — modal dialogs, dropdown menus etc.
    // GUI requests are dispatched via dispatch_async(dispatch_get_main_queue()) from auv3_show_gui_async
    info!("Main thread running NSApp event loop for GUI support");
    unsafe { auv3_run_main_loop(); }

    // unreachable
    Ok(())
}
