# VST3 Plugin Support Design

## Goal

Add full VST3 plugin hosting (discover, load, render audio, show GUI) to strudel-vst-bridge, alongside the existing hand-rolled AUv3 host. VST3 plugins should be fully usable from the browser, identical in capability to AU plugins today.

**Motivations:**
- Many plugins are VST3-only (no AU version)
- Cross-platform path: VST3 works on macOS, Windows, and Linux

## Constraints

- Keep the existing AUv3 host (`auv3_host.m`) untouched — no regressions allowed
- Use the `rack-patched` crate for VST3 scanning, loading, rendering, and MIDI
- VST3 GUI requires new work in `rack-patched` (currently missing)
- When a plugin exists as both AU and VST3, show both with format suffix: `"Odin2 (AU)"` and `"Odin2 (VST3)"`

## Architecture Overview

```
Browser (strudel)
  │
  ▼ WebSocket JSON/Binary
  │
  ┌─────────────────────────────────┐
  │        strudel-vst-bridge       │
  │         (Rust, main.rs)         │
  │                                 │
  │  PluginManager                  │
  │  ├── AU plugins  → auv3_host.m │  (existing, unchanged)
  │  └── VST3 plugins → rack crate │  (new)
  └─────────────────────────────────┘
```

Two parallel hosting backends behind a unified PluginManager, selected by format.

## Design Sections

### 1. Plugin Discovery

**Current:** `auv3_list_plugins()` FFI call returns AU instruments/effects.

**New:** On startup (or on `list_plugins` request), also scan VST3 via `rack::vst3::Vst3Scanner`:

```rust
use rack::prelude::*;
use rack::vst3::Vst3Scanner;

let scanner = Vst3Scanner::new(); // scans default VST3 paths
let vst3_plugins = scanner.scan();
```

**Merge strategy:** Return both lists to the browser. AU plugins get suffix `" (AU)"`, VST3 plugins get `" (VST3)"`. The `pluginId` sent by the browser includes the suffix, so the bridge knows which backend to use.

**Protocol change — `plugin_list` response:**

```json
{
  "type": "plugin_list",
  "plugins": [
    { "name": "Odin2 (AU)", "manufacturer": "TheWaveWarden", "pluginType": "Instrument", "format": "au" },
    { "name": "Odin2 (VST3)", "manufacturer": "TheWaveWarden", "pluginType": "Instrument", "format": "vst3" }
  ]
}
```

The `format` field is added for programmatic filtering. The `name` field includes the suffix for display/selection.

### 2. Plugin Loading

**Current:** `load_plugin` message triggers `auv3_load_plugin()` FFI.

**New:** Parse the format from the `pluginId`:
- If `pluginId` ends with `" (VST3)"` → load via `rack`'s `Vst3Scanner::load()`
- Otherwise → existing AU path (default, backwards-compatible)

```rust
enum LoadedPlugin {
    Au(AUv3Plugin),           // existing opaque FFI handle
    Vst3(rack::vst3::Vst3Plugin),  // rack-managed instance
}
```

The `PluginManager` stores `LoadedPlugin` enum variants. All downstream operations (render, note_on, show_gui) dispatch on this enum.

**Initialization:** After loading, call `vst3_plugin.initialize(SAMPLE_RATE, BLOCK_SIZE)` to match the existing 48kHz / 512-sample configuration.

### 3. Audio Rendering

**Current:** `auv3_render()` FFI fills pre-allocated stereo buffers.

**New for VST3:** Use `rack`'s `PluginInstance::process()`:

```rust
// Pre-allocate buffers (same as AU path)
let mut left = vec![0.0f32; BLOCK_SIZE];
let mut right = vec![0.0f32; BLOCK_SIZE];
let mut outputs = [left.as_mut_slice(), right.as_mut_slice()];

vst3_plugin.process(&[], &mut outputs, BLOCK_SIZE as u32);
```

The rest of the render pipeline (note on → render blocks → note off → release tail → silence detection → binary encode → WebSocket send) remains identical. Only the per-block render call differs.

### 4. MIDI

**Current:** `auv3_note_on()` / `auv3_note_off()` FFI calls.

**New for VST3:** Use `rack`'s `PluginInstance::send_midi()` with typed constructors:

```rust
use rack::midi::MidiEvent;

// Note on: note, velocity, channel, frame_offset
vst3_plugin.send_midi(&[MidiEvent::note_on(60, 100, 0, 0)])?;

// Note off: note, velocity, channel, frame_offset
vst3_plugin.send_midi(&[MidiEvent::note_off(60, 64, 0, 0)])?;
```

**Limitation:** VST3 does not support system real-time MIDI messages (clock, start, stop). This is acceptable — strudel-vst-bridge doesn't use them.

### 5. GUI Display

**Current state in rack:** AU GUI is fully implemented (AUv3 → AUv2 → generic fallback). VST3 GUI is **not implemented**.

**Required work in `rack-patched`:** Add VST3 GUI support by implementing `IPlugView` → NSWindow bridging in `rack-sys`. This involves:

1. **C++ side (`rack-sys/src/vst3_gui.mm`, new file, ~300 lines):**
   - Call `IEditController::createView("editor")` to get an `IPlugView`
   - Query `IPlugView::getSize()` for initial window dimensions
   - Create an `NSView` container, call `IPlugView::attached(nsview, kPlatformTypeNSView)`
   - Wrap in an `NSWindow` with standard decorations
   - Handle `IPlugFrame` callbacks for resize requests
   - Cleanup: `IPlugView::removed()` on window close

2. **Rust side (`rack/src/vst3/gui.rs`, new file):**
   - `Vst3Gui` struct with `show_window(title)` and `hide_window()`
   - FFI bindings to the C++ layer
   - Async creation pattern matching AU GUI (dispatch to main thread)

3. **Integration in strudel-vst-bridge:**
   - `show_gui` message for VST3 plugins calls `vst3_plugin.create_gui()` then `gui.show_window()`
   - Dispatch to main thread via `dispatch_async` (same pattern as AU)

**Fallback:** If a VST3 plugin has no GUI (returns null from `createView`), respond with an error message to the browser. No generic parameter UI for VST3 initially.

### 6. Protocol Changes

Minimal, backwards-compatible changes:

| Message | Change |
|---------|--------|
| `list_plugins` response | Add `format` field (`"au"` or `"vst3"`). Name includes format suffix. |
| `load_plugin` | `pluginId` includes format suffix (e.g. `"Odin2 (VST3)"`). No suffix = AU (backwards-compatible). |
| `render` | No change — works identically for both formats. |
| `show_gui` | No change — works identically for both formats. |
| `plugin_loaded` response | Add `format` field. |

### 7. Error Handling

- VST3 scan failure: Log warning, return AU-only list (graceful degradation)
- VST3 load failure: Return `error` message to browser with details
- VST3 render failure: Return `error` message, don't crash
- VST3 GUI unavailable: Return `error` message (`"Plugin has no GUI"`)

### 8. Threading

No changes to the threading model:
- VST3 audio rendering uses `spawn_blocking` (same as AU)
- VST3 GUI creation dispatches to main thread (same as AU)
- `rack`'s VST3 types are `Send` but not `Sync` — wrap in `Mutex` like AU handles

### 9. What's NOT in Scope

- Migrating AU hosting to `rack` (keep `auv3_host.m` as-is)
- Windows/Linux support (future work — the current bridge is macOS-only due to `auv3_host.m`, `NSApp` event loop, and macOS framework linkage; cross-platform would require `#[cfg]` gates, platform-specific event loops, and per-platform VST3 GUI embedding)
- CLAP support (rack doesn't have it yet)
- Deduplication of AU/VST3 plugins with same name
- Preset management UI
- Multi-instance polyphony

## Implementation Order

1. **Wire up VST3 scanning** — list VST3 plugins alongside AU in `list_plugins`
2. **Wire up VST3 loading + rendering** — `load_plugin` and `render` for VST3
3. **Wire up VST3 MIDI** — note on/off via rack
4. **Add VST3 GUI to rack-patched** — `IPlugView` → NSWindow in rack-sys
5. **Wire up VST3 GUI in bridge** — `show_gui` for VST3 plugins
6. **Test end-to-end** — load a VST3-only plugin, render audio, open GUI

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| rack's VST3 rendering has bugs | Medium | Test with multiple plugins early; can fix in rack-patched |
| VST3 GUI implementation is complex | Low-Medium | IPlugView API is well-documented; ~300 lines of ObjC++ |
| Thread safety issues with VST3 | Low | rack already has global mutex for VST3 lifecycle |
| Some VST3 plugins crash on load | Medium | Wrap in catch; return error to browser |
