# strudel-vst-bridge

WebSocket bridge that hosts AudioUnit plugins on macOS and renders audio on demand for [strudel](https://strudel.cc) live coding.

Works with [strudel-experiment](https://github.com/kink80/strudel-experiment) — a fork of strudel with VST/AU bridge integration.

## How it works

```
Browser (strudel)                         Bridge (this project)
─────────────────                         ────────────────────
note("c3 e3 g3").vst("Odin2")
  → WebSocket JSON ──────────────────────→ Loads Odin2 AudioUnit
    { note: 60, velocity: 0.8, ... }       Sends MIDI note on
                                           Renders audio blocks
  ← Binary PCM float32 ◄────────────────  Sends note off, captures release
  AudioWorklet plays buffer
```

The bridge hosts plugins via Apple's AUv3 API (`AUAudioUnit`), so the same instance handles both audio rendering and native GUI display. Audio is rendered offline (faster than realtime, ~5-7ms per note) and streamed back as PCM over WebSocket binary frames.

## Requirements

- macOS (AudioUnit backend)
- Rust toolchain (`cargo`)
- AudioUnit instrument plugins installed (e.g. Odin2, Dexed, MS-20)

## Quick start

```bash
# Build and run the bridge
cargo run

# In strudel (strudel-experiment fork):
# note("c3 e3 g3 c4").vst("Odin2")
```

The bridge listens on `ws://localhost:8765` and automatically scans for installed AudioUnit plugins on startup.

## Usage in strudel

```js
// Play notes through a plugin — note pattern provides the structure
note("[c3 e3 g3 c4]*2").vst("Odin2")

// Open the native plugin GUI
vstGui("Odin2")

// List available plugins
vstList()

// List plugin parameters (filter by name)
vstListParams("Odin2", "filter")

// Set parameters (normalized 0-1)
note("c3 e3 g3").vst("Odin2").vstparams({"Filter1 Frequency": 0.3})
```

The VST panel in strudel's sidebar lets you browse, load, and open plugin GUIs with a click.

## Protocol

### Browser → Bridge (JSON)

```json
{ "type": "load_plugin", "pluginId": "Odin2" }
{ "type": "render", "requestId": 1, "pluginId": "Odin2", "note": 60, "velocity": 0.8, "duration": 1.0, "params": {} }
{ "type": "show_gui", "pluginId": "Odin2" }
{ "type": "list_plugins" }
```

### Bridge → Browser (JSON)

```json
{ "type": "plugin_loaded", "pluginId": "Odin2", "name": "Odin2", "params": [...] }
{ "type": "gui_opened", "pluginId": "Odin2" }
{ "type": "plugin_list", "plugins": [{ "name": "Odin2", "manufacturer": "TheWaveWarden", "pluginType": "Instrument" }, ...] }
{ "type": "error", "message": "..." }
```

### Bridge → Browser (Binary)

Rendered audio as little-endian binary:

```
[uint32 requestId] [uint32 numSamples] [float32[] left channel] [float32[] right channel]
```

## Architecture

- **`src/main.rs`** — Rust WebSocket server (tokio + tokio-tungstenite), plugin management, audio rendering orchestration
- **`src/auv3_host.m`** — Objective-C AUv3 plugin host: plugin instantiation, MIDI, audio rendering, native GUI windows
- **`build.rs`** — Compiles the Objective-C code and links macOS frameworks

The main thread runs `[NSApp run]` for proper macOS event handling (required for JUCE plugin GUIs — dropdowns, modal dialogs). The tokio WebSocket server runs on a background thread. GUI requests are dispatched to the main thread via `dispatch_async(dispatch_get_main_queue(), ...)`.

## Known limitations

- macOS only (AudioUnit backend)
- Plugin GUI is a floating native window, not embedded in the browser
- Some plugin presets may be silent (wavetable loading edge cases)
- One plugin instance per name (no polyphonic multi-instance hosting yet)

## License

MIT
