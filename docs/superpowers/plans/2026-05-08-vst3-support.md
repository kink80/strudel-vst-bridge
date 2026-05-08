# VST3 Plugin Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add VST3 plugin hosting (discover, load, render, MIDI, GUI) alongside the existing AU host, using the `rack` crate for VST3 and keeping `auv3_host.m` untouched.

**Architecture:** Two parallel hosting backends (`auv3_host.m` for AU, `rack::vst3` for VST3) behind a unified `PluginManager` that dispatches based on a `LoadedPlugin` enum. VST3 plugins appear in the browser with `" (VST3)"` suffix; AU plugins get `" (AU)"` suffix. The WebSocket protocol is backwards-compatible with a new `format` field.

**Tech Stack:** Rust 2021, `rack` crate (VST3 scanner/plugin/MIDI), Objective-C (existing AU host), tokio + tungstenite (WebSocket server)

**Spec:** `docs/superpowers/specs/2026-05-08-vst3-support-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/main.rs` | Modify | Add `LoadedPlugin` enum, VST3 scanning, VST3 load/render/MIDI/GUI dispatch |
| `Cargo.toml` | No change | `rack` dependency already present |
| `build.rs` | No change | Only compiles `auv3_host.m`, rack handles its own build |

This is a single-file change (plus the rack dependency that's already wired up). The existing `auv3_host.m` is not touched.

---

### Task 1: Add LoadedPlugin enum and format detection

**Files:**
- Modify: `src/main.rs:56-68` (PluginHandle area)

- [ ] **Step 1: Add rack imports and LoadedPlugin enum after the existing PluginHandle**

Add these imports at the top of `src/main.rs` (after line 15):

```rust
use rack::vst3::{Vst3Scanner, Vst3Plugin};
use rack::{MidiEvent, PluginInstance, PluginScanner, PluginInfo as RackPluginInfo, PluginType as RackPluginType};
```

Add the `LoadedPlugin` enum after the `PluginHandle` struct (after line 68):

```rust
enum LoadedPlugin {
    Au(Arc<StdMutex<PluginHandle>>),
    Vst3(Arc<StdMutex<Vst3PluginHandle>>),
}

struct Vst3PluginHandle {
    plugin: Vst3Plugin,
    name: String,
    info: RackPluginInfo,
}

unsafe impl Send for Vst3PluginHandle {}
```

- [ ] **Step 2: Add helper to detect format from pluginId**

Add after the `LoadedPlugin` enum:

```rust
fn parse_plugin_format(plugin_id: &str) -> (&str, &str) {
    if let Some(name) = plugin_id.strip_suffix(" (VST3)") {
        (name, "vst3")
    } else if let Some(name) = plugin_id.strip_suffix(" (AU)") {
        (name, "au")
    } else {
        (plugin_id, "au") // default to AU for backwards compatibility
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `cargo check 2>&1 | head -20`
Expected: Compiles (warnings about unused types are fine at this stage)

- [ ] **Step 4: Commit**

```bash
git add src/main.rs
git commit -m "feat: add LoadedPlugin enum and format detection for VST3 support"
```

---

### Task 2: Update PluginManager to support both formats

**Files:**
- Modify: `src/main.rs:145-192` (PluginManager)

- [ ] **Step 1: Add Vst3Scanner and dual-format storage to PluginManager**

Replace the `PluginManager` struct and its `impl` block (lines 145-192) with:

```rust
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
            info,
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
```

- [ ] **Step 2: Verify it compiles**

Run: `cargo check 2>&1 | head -30`
Expected: Compile errors in the WebSocket handler because it still uses `mgr.get_plugin()`. This is expected — we'll fix it in Task 3.

- [ ] **Step 3: Commit**

```bash
git add src/main.rs
git commit -m "feat: update PluginManager with dual AU/VST3 backends"
```

---

### Task 3: Add VST3 render function

**Files:**
- Modify: `src/main.rs:196-265` (render_note area)

- [ ] **Step 1: Add render_note_vst3 function after render_note**

Add after the existing `render_note` function (after line 265):

```rust
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
```

- [ ] **Step 2: Verify it compiles**

Run: `cargo check 2>&1 | head -20`
Expected: May have warnings about unused functions, compile errors in handler. Fine for now.

- [ ] **Step 3: Commit**

```bash
git add src/main.rs
git commit -m "feat: add VST3 audio rendering function"
```

---

### Task 4: Update WebSocket handler for dual-format dispatch

**Files:**
- Modify: `src/main.rs:281-433` (handle_connection function)

This is the largest task — we update every handler branch to dispatch AU vs VST3.

- [ ] **Step 1: Update the Render handler (lines 324-367)**

Replace the `IncomingMessage::Render` match arm with:

```rust
                    IncomingMessage::Render { request_id, plugin_id, note, velocity, duration, params } => {
                        let (_, format) = parse_plugin_format(&plugin_id);

                        // Auto-load plugin on first render if not loaded
                        {
                            let mut mgr = manager.lock().await;
                            let needs_load = match format {
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

                        let result = match format {
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
```

- [ ] **Step 2: Update the ShowGui handler (lines 369-394)**

Replace the `IncomingMessage::ShowGui` match arm with:

```rust
                    IncomingMessage::ShowGui { plugin_id } => {
                        let (_, format) = parse_plugin_format(&plugin_id);

                        // Auto-load plugin if not loaded
                        {
                            let mut mgr = manager.lock().await;
                            let needs_load = match format {
                                "vst3" => mgr.get_vst3_plugin(&plugin_id).is_none(),
                                _ => mgr.get_au_plugin(&plugin_id).is_none(),
                            };
                            if needs_load {
                                info!("Auto-loading plugin for GUI: {plugin_id}");
                                let _ = mgr.load_plugin(&plugin_id);
                            }
                        }

                        match format {
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
```

- [ ] **Step 3: Update the LoadPlugin handler (lines 313-321)**

Replace the `IncomingMessage::LoadPlugin` match arm with:

```rust
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
```

(This is nearly identical to the existing code — `mgr.load_plugin` now dispatches internally.)

- [ ] **Step 4: Verify it compiles**

Run: `cargo check 2>&1 | head -30`
Expected: Should compile. The `ListPlugins` handler still needs updating (Task 5).

- [ ] **Step 5: Commit**

```bash
git add src/main.rs
git commit -m "feat: update WebSocket handler for AU/VST3 dual dispatch"
```

---

### Task 5: Update ListPlugins to include VST3 plugins

**Files:**
- Modify: `src/main.rs` (ListPlugins handler, around line 396-426)

- [ ] **Step 1: Add `format` field to PluginEntry and merge AU + VST3 lists**

Replace the `IncomingMessage::ListPlugins` match arm with:

```rust
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
```

- [ ] **Step 2: Update startup log message**

Change line 450 from:
```rust
info!("strudel-vst-bridge listening on ws://{addr} (AUv3 backend)");
```
to:
```rust
info!("strudel-vst-bridge listening on ws://{addr} (AU + VST3 backends)");
```

- [ ] **Step 3: Verify it compiles and builds**

Run: `cargo build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add src/main.rs
git commit -m "feat: list VST3 plugins alongside AU in plugin discovery"
```

---

### Task 6: End-to-end smoke test

**Files:**
- No file changes — manual testing

- [ ] **Step 1: Run the bridge**

Run: `cargo run 2>&1`
Expected: Should print startup log with "AU + VST3 backends" and list found VST3 plugins count.

- [ ] **Step 2: Test list_plugins via wscat or similar**

Connect to `ws://127.0.0.1:8765` and send:
```json
{"type":"list_plugins"}
```

Expected: Response includes both `(AU)` and `(VST3)` suffixed plugins with `format` field.

- [ ] **Step 3: Test loading a VST3 plugin**

Send (using a VST3 plugin name from the list):
```json
{"type":"load_plugin","pluginId":"<PluginName> (VST3)"}
```

Expected: `plugin_loaded` response.

- [ ] **Step 4: Test rendering a note through VST3**

Send:
```json
{"type":"render","requestId":1,"pluginId":"<PluginName> (VST3)","note":60,"velocity":0.8,"duration":0.5}
```

Expected: Binary PCM response (non-zero audio if plugin is an instrument).

- [ ] **Step 5: Test that AU still works**

Send:
```json
{"type":"load_plugin","pluginId":"<PluginName> (AU)"}
```

Expected: `plugin_loaded` response (AU path unchanged).

- [ ] **Step 6: Test backwards compatibility (no suffix)**

Send:
```json
{"type":"load_plugin","pluginId":"<PluginName>"}
```

Expected: Loads via AU path (default, backwards-compatible).

- [ ] **Step 7: Commit any fixes discovered during testing**

```bash
git add -A
git commit -m "fix: address issues found during VST3 smoke testing"
```

(Only if fixes were needed.)

---

### Task 7: VST3 GUI stub (future-ready)

**Files:**
- Modify: `src/main.rs` (ShowGui handler — already done in Task 4)

This task is already implemented in Task 4 — the ShowGui handler returns `"VST3 GUI not yet supported"` for VST3 plugins. No additional work needed now.

When `rack-patched` gains VST3 GUI support (via `IPlugView` → NSWindow bridging in rack-sys), the ShowGui handler can be updated to call `rack`'s GUI API. This is tracked as a separate future task.

- [ ] **Step 1: Verify the error message works**

Send:
```json
{"type":"show_gui","pluginId":"<PluginName> (VST3)"}
```

Expected: `{"type":"error","pluginId":"<PluginName> (VST3)","message":"VST3 GUI not yet supported"}`

- [ ] **Step 2: Done**

No commit needed — already covered by Task 4.
