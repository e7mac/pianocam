# PianoCam

A macOS Camera Extension that exposes a virtual webcam to Zoom / Teams / QuickTime / OBS, showing your real webcam with an 88-key piano overlay along the bottom. Keys light up in real time when you play a connected USB MIDI controller (or any CoreMIDI source — VMPK, IAC bus, GarageBand, etc.). Free, MIT-licensed.

## Architecture

Two targets in one Xcode project:

- **PianoCam** (host app) — captures your real webcam, listens for MIDI, composites the final 1280×720 frame, and pushes it to the Camera Extension via a CMIO sink stream.
- **PianoCamExtension** (camera system extension) — registers as a virtual camera, receives composited frames over the sink, and republishes them to consumers like QuickTime/Zoom.

The sink-stream pattern means the extension stays simple — all the rendering happens in the host app; the extension is a thin pipe.

```
your webcam ─┐                                  ┌─→ Zoom
             ├─→ host app ─(sink stream)─→ ext  │   QuickTime
   MIDI ─────┘   composites + sends             └─→ OBS / etc.
```

Built on top of [@ldenoue/cameraextension](https://github.com/ldenoue/cameraextension) — thanks for the working CMIO scaffolding.

## Features

- 88-key piano overlay (MIDI 21 → 108) with realistic key proportions, felt strip, rounded fronts.
- Velocity-scaled glow (soft notes are dim, fortissimo is bright cyan-white).
- Sustain pedal (CC64) holds notes lit while down.
- All-notes-off (CC123) clears the keyboard.
- Camera picker — switch between built-in / external / Continuity Cameras.
- Automatic MIDI source binding — connects to every CoreMIDI source, hot-plug aware.
- In-app preview window showing exactly what consumers will see.

## Build & install

Requires:
- Xcode 15+ on macOS 14+.
- A paid Apple Developer Program membership (the camera-extension entitlement requires real signing).

```bash
git clone https://github.com/e7mac/pianocam.git
cd pianocam
open PianoCam.xcodeproj
```

In Xcode, for **both** the `PianoCam` and `PianoCamExtension` targets:

1. Signing & Capabilities → Team → pick your Developer Program team.
2. Make sure **Automatically manage signing** is on.

Build (⌘B). Then quit any running PianoCam, drag `PianoCam.app` from `Products/Debug/` to `/Applications/`, and launch it from there.

> Camera Extensions can only be activated when the host app lives in `/Applications` (not `DerivedData`). Run from `/Applications` or you'll get "extension not found" errors.

In the app window:
1. Pick your real webcam from the dropdown.
2. Click **activate** → approve the extension in System Settings → Privacy & Security → Login Items & Extensions → Camera Extensions.
3. Open QuickTime → File → New Movie Recording → camera dropdown → **PianoCam**.
4. Play notes on a MIDI controller (or send via VMPK / IAC Bus / etc.) — keys light up in QuickTime in real time.

## Repo layout

```
pianocam/
├── PianoCam.xcodeproj                # Xcode project
├── PianoCam/                         # Host app target
│   ├── AppDelegate.swift
│   ├── ViewController.swift          # UI + frame loop pushing to sink
│   ├── CameraCapture.swift           # AVCaptureSession wrapper
│   ├── MIDIInput.swift               # CoreMIDI client + parser
│   ├── PianoState.swift              # active notes / sustain model
│   └── PianoCam.entitlements
├── PianoCamExtension/                # Camera system extension target
│   ├── main.swift                    # CMIOExtensionProvider.startService entry
│   ├── PianoCamExtensionProvider.swift  # Provider + DeviceSource + StreamSource
│   ├── Config.swift
│   ├── Info.plist                    # CMIOExtension dict, no NSExtension dict
│   └── PianoCamExtension.entitlements
├── Shared/
│   └── PianoOverlay.swift            # 88-key keyboard renderer, compiled into both targets
└── tools/
    ├── add_shared_file.rb            # Add a Swift file to all targets
    ├── add_target_file.rb            # Add a Swift file to one target
    ├── rename_targets.rb             # One-time rename helper, kept for reference
    └── midi-test-sender.swift        # CLI tool: sends a C-major scale to IAC Bus 1
```

## Why no XcodeGen?

Earlier iterations used XcodeGen, but install kept failing with "extension not found in app bundle." The root cause was a tiny shape difference vs. Apple's working CMIO sample: an `NSExtension` dict that should NOT be present, an `XPC!` bundle type instead of `SYSX`, a sandboxed host app, and an app-group named with just `<TeamID>.<host_bundle_id>` (no `group.` prefix). Easier to fork [@ldenoue/cameraextension](https://github.com/ldenoue/cameraextension)'s known-working `pbxproj` and add files via the `xcodeproj` Ruby gem than re-derive every nuance in YAML.

## License

MIT.
