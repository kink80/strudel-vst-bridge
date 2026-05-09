# strudel-vst-bridge

Use your AudioUnit synthesizer plugins (Odin2, Dexed, Vital, etc.) directly from [strudel](https://strudel.cc) live coding patterns. The bridge runs in the background on your Mac, and strudel sends it notes to render through your plugins.

Works with [strudel-experiment](https://github.com/kink80/strudel-experiment) — a fork of strudel with VST/AU bridge integration.

## Getting started

### Option 1: Download the binary (easiest)

1. Download the latest release from the [Releases page](https://github.com/kink80/strudel-vst-bridge/releases/latest)
2. Extract and run:

```bash
tar xzf strudel-vst-bridge-macos-universal.tar.gz
xattr -cr strudel-vst-bridge   # needed once — allows unsigned binary to run
./strudel-vst-bridge
```

The binary works on both Apple Silicon and Intel Macs.

### Option 2: Build from source

```bash
git clone https://github.com/kink80/strudel-vst-bridge.git
cd strudel-vst-bridge
cargo run
```

Requires Rust (install from [rustup.rs](https://rustup.rs)).

### What you'll see

When the bridge starts, it scans your installed AudioUnit plugins and listens on `ws://localhost:8765`. You should see your plugins listed in the terminal output.

Now open [strudel-experiment](https://github.com/kink80/strudel-experiment) in your browser and try:

```js
note("c3 e3 g3 c4").vst("Odin2")
```

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

## Troubleshooting

**"macOS cannot verify the developer"** — Run `xattr -cr strudel-vst-bridge` once after downloading, or right-click the file and choose Open.

**No plugins show up** — Make sure you have AudioUnit (AU) plugins installed. Most popular synths (Vital, Dexed, Odin2, Surge XT) ship with an AU version. Check that they appear in other AU hosts like GarageBand.

**Connection refused in strudel** — Make sure the bridge is running before you evaluate a pattern. It should be listening on `ws://localhost:8765`.

## Known limitations

- macOS only (AudioUnit backend)
- Plugin GUI is a floating native window, not embedded in the browser
- Some plugin presets may be silent (wavetable loading edge cases)

## License

MIT
