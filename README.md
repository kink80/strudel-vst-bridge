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

## How it works

### Instance-based workflow

Plugins are managed as **named instances**. You create instances in strudel's VST panel, giving each a label. Multiple instances of the same plugin are independent — each has its own parameter state and GUI.

1. Open the **VST panel** in strudel's sidebar
2. Find a plugin and type a label (e.g. `bass`), click **+**
3. The bridge loads a new instance of that plugin
4. Use the label in your code:

```js
note("c3 e3 g3 c4").vst("bass")
```

5. Click **GUI** to open the native plugin window and tweak parameters

You can create multiple instances of the same plugin with different labels:

```js
// Two independent Odin2 instances with different sounds
note("[c3 e3 g3 c4]*2").vst("pad")
note("a1 a1").vst("bass")
```

Instances persist on the bridge across page reloads — when you refresh the browser, the VST panel re-fetches the instance list automatically.

```
Browser (strudel)                         Bridge (this project)
─────────────────                         ────────────────────
Create instance "bass" → Odin2
  → { type: "create_instance",           Loads Odin2 AudioUnit,
      label: "bass",                      stores as "bass"
      pluginName: "Odin2" }

note("c3 e3").vst("bass")
  → { type: "render",                    Looks up "bass" instance
      pluginId: "bass",                   Sends MIDI note on
      note: 60, ... }                     Renders audio blocks
  ← Binary PCM float32 ◄────────────────  Sends note off, captures release
  AudioWorklet plays buffer
```

The bridge hosts plugins via Apple's AUv3 API (`AUAudioUnit`), so the same instance handles both audio rendering and native GUI display. Audio is rendered offline (faster than realtime, ~5-7ms per note) and streamed back as PCM over WebSocket binary frames.

## Usage in strudel

```js
// Play notes through a named instance
note("[c3 e3 g3 c4]*2").vst("pad")

// Open the native plugin GUI
vstGui("pad")

// List available plugins
vstList()

// List plugin parameters (filter by name)
vstListParams("bass", "filter")

// Set parameters (normalized 0-1)
note("c3 e3 g3").vst("bass").vstparams({"Filter1 Frequency": 0.3})
```

Instances are created and managed in the VST panel — browse plugins, create labeled instances, open GUIs, and delete instances from the UI.

## Protocol

### Browser → Bridge (JSON)

```json
{ "type": "create_instance", "label": "bass", "pluginName": "Odin2" }
{ "type": "delete_instance", "label": "bass" }
{ "type": "list_instances" }
{ "type": "render", "requestId": 1, "pluginId": "bass", "note": 60, "velocity": 0.8, "duration": 1.0, "params": {} }
{ "type": "show_gui", "pluginId": "bass" }
{ "type": "list_plugins" }
```

### Bridge → Browser (JSON)

```json
{ "type": "instance_created", "label": "bass", "pluginName": "Odin2", "params": [] }
{ "type": "instance_deleted", "label": "bass" }
{ "type": "instance_list", "instances": [{ "label": "bass", "pluginName": "Odin2" }, ...] }
{ "type": "gui_opened", "pluginId": "bass" }
{ "type": "plugin_list", "plugins": [{ "name": "Odin2", "manufacturer": "TheWaveWarden", "pluginType": "Instrument" }, ...] }
{ "type": "error", "message": "..." }
```

### Bridge → Browser (Binary)

Rendered audio as little-endian binary:

```
[uint32 requestId] [uint32 numSamples] [float32[] left channel] [float32[] right channel]
```

## Architecture

- **`src/main.rs`** — Rust WebSocket server (tokio + tokio-tungstenite), instance registry, audio rendering orchestration
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
- Instances persist only while the bridge process is running (no disk persistence yet)

## License

MIT
