# Spectrum

A real-time Audio Unit host for macOS that listens to **your system audio** (or any audio input), runs it through a chain of AU plugins such as FabFilter Pro‑Q 4 or ADPTR MetricAB, and plays the result through the output of your choice. Use your favourite analyzers, EQs and limiters "stand-alone" on top of Spotify, YouTube, your DAW, anything.

```
Other apps ──► Core Audio tap ──► Spectrum ──► Pro‑Q 4 ──► (more plugins) ──► Speakers / Headphones
```

While Spectrum is running, the original output of the other apps is muted (optional) so you only hear the processed signal. Stop or quit Spectrum and everything returns to normal.

## Requirements

- **macOS 14.2 (Sonoma) or later.** Spectrum uses the native Core Audio *process tap* API, so it needs no BlackHole or virtual drivers. Apple Silicon and Intel are both supported.
- **AU plugins installed** in `/Library/Audio/Plug-Ins/Components` (and licensed on that Mac).
- To build from source: the **Xcode Command Line Tools** (`xcode-select --install`). Full Xcode is not required.

## Install

### Option A: build from source (recommended)

```bash
xcode-select --install          # first time only
git clone https://github.com/ekomeme/Spectrum.git
cd Spectrum
./build.sh --install            # builds, ad-hoc signs and copies to /Applications
```

Then launch Spectrum from Launchpad or Spotlight.

### Option B: download the prebuilt app

The **Releases** tab has a universal `Spectrum.zip` (Apple Silicon + Intel). Unzip it and drag `Spectrum.app` to Applications.

The app is ad-hoc signed and not notarized, so macOS will block it the first time you open a downloaded copy ("cannot be opened because the developer cannot be verified"). Either:

- Try to open it once, then go to System Settings → Privacy & Security and click **Open Anyway**, or
- Remove the quarantine flag from Terminal: `xattr -dr com.apple.quarantine /Applications/Spectrum.app`

### Permissions

The first time you press **Start**, macOS asks for **System Audio Recording** permission (and **Microphone** if you choose a hardware input). Accept them. If you declined by mistake: System Settings → Privacy & Security → Screen & System Audio Recording → enable Spectrum.

> Each rebuild changes the ad-hoc signature, so macOS may ask for the permission again after updating. If you have a developer certificate you can sign with it:
> `CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh`

## Usage

The window has two tabs, System Settings style:

**Plugin Chain**
- **Add Plugin…** opens a searchable list of every AU effect on your Mac. Pick one (say, Pro‑Q 4) and its editor opens; reopen it any time with **Editor**.
- Plugins run top to bottom. Reorder them with the chevrons, **Bypass** one, or remove it with the minus button.

**Audio Settings**
- **Source**: "System audio (all apps)" or a specific input device (microphone, interface, BlackHole…).
- **Output**: the device you want to listen on. It can differ from the system default.
- **Buffer size**: 64–1024 frames. Smaller means less latency and more CPU; 256 is a good default.
- **Mute original audio**: with the system-audio source, silences the other apps' direct output so you only hear the processed path. Turn it off to hear both.

The bottom bar (output meters, status, **Start / Stop**) is always visible. Closing the window with the X keeps Spectrum running from the menu bar icon (waveform); from there you can show the window, start/stop or quit.

On quit, Spectrum saves the plugin chain with each plugin's full state (EQ curves, presets…), the selected devices and whether it was running, and restores all of it on the next launch. The session lives in `~/Library/Application Support/Spectrum/session.plist`.

## How it works

- `SystemAudioTap` creates a global stereo *process tap* (`CATapDescription`) that excludes Spectrum's own process, so the processed signal is never captured again (no feedback). With `muteBehavior = .mutedWhenTapped` the system silences the original audio while the tap is active.
- `AggregateDevice` builds a private aggregate device with the output device as clock master plus the tap (or the chosen input device). One device for input and output means no clock drift.
- `AudioEngineController` opens an `IOProc` on that device. On every callback `RealtimeRenderer` de-interleaves the input, renders the plugin chain in series through the classic `AudioUnitRender` API with the device's real timestamp (sample time and host time), and writes the result into the first two output channels. Total latency is one buffer plus whatever the plugins add.
- Plugins are loaded in-process with `AVAudioUnit.instantiate`, initialised once and kept initialised across stop/start (only a sample-rate change re-initialises them). Their editors are created through `kAudioUnitProperty_CocoaUI` on every open, with `requestViewController` and `AUGenericView` as fallbacks.
- `TransportClock` answers host-callback queries with "playing", a monotonic sample position and a fixed tempo; analyser plugins freeze their displays without it.

### Things that did not work (so you don't retry them)

- Pointing `AVAudioEngine.inputNode` at an aggregate device: the engine keeps reporting zero input channels.
- `AVAudioEngine` in manual rendering mode: it re-initialises every plugin on each stop/start, which freezes some analysers.
- `AUAudioUnit.renderBlock` for hosting v2 plugins: the bridge returns `kAudioUnitErr_NoConnection` for plugins with a side-chain bus (Pro‑Q 4, Pro‑L 2) and never pulls input.
- Letting the process exit normally with certain plugins loaded: MetricAB crashes in its own static destructors, so Spectrum saves the session and ends with `_exit(0)`.

## Diagnostics from the terminal

```bash
.build/release/Spectrum --list                          # audio devices and installed AU effects
.build/release/Spectrum --probe "pro-q"                 # instantiate a plugin, check format/UI/state
.build/release/Spectrum --render-probe "pro-q"          # render one block via v3 renderBlock and v2 AudioUnitRender
.build/release/Spectrum --selftest <inUID> <outUID> [--with-proq] [--tone] [--add-late]
.build/release/Spectrum --probe-transport "metricab" <inUID> <outUID>
.build/release/Spectrum --ui-smoke "metricab"           # open/close the editor three times
```

`--selftest` runs the real signal path for two seconds, hot-adds and removes Pro‑Q 4, cycles stop/start and reports callbacks, channels, failed renders and output peak. `--tone` replaces the input with a −34 dB sine to verify the whole path.

## Project layout

```
Sources/Spectrum/
  main.swift                         Entry point and diagnostic modes
  AppDelegate.swift                  Menus, menu bar item, lifecycle, session save
  Audio/AudioDevice.swift            Device enumeration and Core Audio helpers
  Audio/SystemAudioTap.swift         Process tap + aggregate device
  Audio/RealtimeRenderer.swift       IOProc → plugin chain (realtime thread)
  Audio/AudioEngineController.swift  Devices, chain management, persistence
  Audio/TransportClock.swift         Host callbacks (transport/tempo) for plugins
  Audio/PluginCatalog.swift          AU listing
  Audio/PluginSlot.swift             One loaded plugin + session models
  UI/MainWindowController.swift      Control panel
  UI/PluginPickerController.swift    Searchable plugin picker
  UI/PluginWindowController.swift    Plugin editor window
Resources/Info.plist, AppIcon.icns
build.sh                             Builds and packages build/Spectrum.app
```

## Build for development

```bash
./build.sh                     # build/Spectrum.app for this Mac
./build.sh --universal --zip   # universal binary + zip for distribution
open build/Spectrum.app
```

## Contributing

Contributions are welcome. If you find a bug or want to propose an improvement:

1. Open an *issue* describing the problem or idea (include macOS version, audio device and plugin if relevant).
2. For code changes, fork the repo, create a branch and open a *pull request* against `main`.
3. Before submitting, make sure it builds and the diagnostics pass:

```bash
./build.sh
.build/release/Spectrum --ui-smoke "pro-q"
.build/release/Spectrum --selftest <inUID> <outUID> --tone --add-late
```

Ideas on the list: Spanish localisation, whole-chain presets, global keyboard shortcuts for bypass, total latency readout, VST3 support through a wrapper.

## License

[MIT](LICENSE). Spectrum does not include or distribute any plugin. FabFilter, Pro‑Q, ADPTR MetricAB and the other names mentioned are trademarks of their respective owners and appear only as usage examples.
