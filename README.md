# PianoCam

A macOS app that overlays an 88-key piano on your webcam feed and lights up keys in real time as you play a connected USB MIDI controller.

License: MIT.

## Status

**Phase 1** — Windowed preview app. ✅
**Phase 2** (in progress) — Camera Extension scaffolding. Currently emits a moving test pattern; IPC from host app pending (Phase 2.5).

## Tech stack

Apple frameworks only. No SwiftPM packages, no CocoaPods.

- Swift 5.9, SwiftUI, AppKit
- AVFoundation (capture)
- CoreMIDI (input)
- macOS 13+, universal (arm64 + x86_64)

## Build

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) and a paid Apple Developer Program membership (the Camera Extension entitlement requires real signing).

```
cd pianocam
xcodegen generate
open PianoCam.xcodeproj
```

In Xcode for **both** the `PianoCam` and `PianoCamExtension` targets:

1. **Signing & Capabilities** → **Team**: pick your Developer Program team.
2. Make sure **Automatically manage signing** is on.

Then build and run the `PianoCam` scheme. On first launch macOS prompts for camera access.

To install the virtual camera, open **PianoCam → Settings → Virtual Camera → Install**. macOS will prompt you to approve the system extension in **System Settings → Privacy & Security**. After approval, "PianoCam" appears as a camera in QuickTime / Zoom / etc.

If the install fails with an unsigned-extension error during local development, run once:
```
sudo systemextensionsctl developer on
```
This permits unsigned/locally-signed extensions for testing only — re-sign with your Developer ID for distribution.

## Phase 1 acceptance

Launch app → see your face + piano overlay → play MIDI keys → keys light up with <50ms perceived latency.

## File layout

```
pianocam/
├── project.yml                       # XcodeGen spec
├── README.md
└── PianoCam/
    ├── App.swift                     # @main, scene setup
    ├── Info.plist
    ├── PianoCam.entitlements
    ├── Capture/
    │   └── CameraSession.swift       # AVCaptureSession wrapper
    ├── MIDI/
    │   ├── MIDIInput.swift           # CoreMIDI client + parser
    │   └── PianoState.swift          # Note/velocity/sustain model
    ├── Overlay/
    │   └── PianoKeyboardView.swift   # 88-key Canvas renderer
    └── UI/
        ├── ContentView.swift         # Camera + overlay composition
        ├── CameraPreviewView.swift   # NSViewRepresentable preview
        └── SettingsView.swift        # Camera/MIDI pickers
```
