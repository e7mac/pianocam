# PianoCam

macOS app + CMIO Camera Extension. The host app composites your real webcam with an 88-key piano overlay driven by CoreMIDI (or acoustic pitch detection), then pipes frames through a sink stream to a virtual camera that Zoom, QuickTime, and OBS can use.

## Building

```bash
open PianoCam.xcodeproj
```

- Requires Xcode 15+, macOS 14+, **paid Apple Developer Program** membership (camera-extension entitlement requires real signing)
- Set a Developer Program team on **both** the `PianoCam` and `PianoCamExtension` targets
- Enable "Automatically manage signing" on both targets
- **The extension only activates when the host app lives in `/Applications`** — drag `PianoCam.app` from `Products/Debug/` to `/Applications/` and launch from there; running from DerivedData gives "extension not found" errors

**Do not use XcodeGen** — the project uses a hand-maintained `.pbxproj` forked from [@ldenoue/cameraextension](https://github.com/ldenoue/cameraextension). Subtle `.pbxproj` details (no `NSExtension` dict, `SYSX` bundle type, app-group without `group.` prefix) are what make CMIO registration work.

### Adding source files

Use the Ruby scripts (requires `gem install xcodeproj`):
```bash
# Add to all targets (Shared/)
ruby tools/add_shared_file.rb PianoCam.xcodeproj Shared/MyFile.swift Shared

# Add to one target
ruby tools/add_target_file.rb PianoCam.xcodeproj PianoCam PianoCam/MyFile.swift PianoCam
```

## Architecture

Two targets communicate via a CMIO sink stream:

```
webcam ─┐
        ├─→ PianoCam (host app) ─(CMSimpleQueue sink)─→ PianoCamExtension ─→ Zoom / QuickTime / OBS
MIDI  ──┘   composites + sends                           thin pipe
```

### Host app (PianoCam/)

`ViewController.swift` (~970 lines) is the core orchestrator:
- `fireTimer()` at 30 Hz: calls `makeCompositeFrame()` → pushes pixel buffer to sink queue
- `connectToCamera()` / `initSink()`: finds the extension in CMIO device list, sets up `CVPixelBufferPool` and `CMSimpleQueue`
- `needToStream` flag: set by reading the extension's "sc=" property — stops pushing frames when no consumer is connected (saves CPU)

### Camera extension (PianoCamExtension/)

`PianoCamExtensionProvider.swift` is a thin pipe:
- `cameraStreamSink`: receives pixel buffers from host's `CMSimpleQueue`
- `consumeBuffer()`: async loop reads from sink, forwards to `cameraStreamSource`
- `cameraStreamSource`: what Zoom/QuickTime sees
- Fallback: if no host frames for >1s, generates a placeholder frame ("PianoCam is ready" + empty keyboard)

### Shared/ (compiled into both targets)

- `PianoOverlay.swift` — pure CoreGraphics 88-key rendering; used both in host composite and in extension fallback
- `PianoKeyboardGeometry.swift` — parametric key geometry + homography fitting for overhead camera
- `BasicPitchModel.swift`, `VocalIsolator.swift` — CoreML model loading

## Key Source Files

| File | What it does |
|---|---|
| `ViewController.swift` | Main orchestrator: camera capture, MIDI, compositing, sink stream |
| `MIDIInput.swift` | CoreMIDI 1.0+2.0 (UMP); auto hot-plugs all sources; parses note-on/off, CC64/66/67/123 |
| `PianoState.swift` | Thread-safe note tracking; `renderedVelocities(at:)` applies 1.5s exponential decay |
| `CameraCapture.swift` | `AVCaptureSession` wrapper; filters out the virtual PianoCam device from picker |
| `AudioPitchDetector.swift` | YIN (monophonic) or Basic Pitch (polyphonic ML) pitch detection from mic |
| `PianoKeyboardAlignmentDetector.swift` | Vision-based black-key detection → homography for overhead camera overlay |
| `ControlPanel.swift` | SwiftUI control panel: camera picker, activate button, pitch detection toggles, Basic Pitch sliders |
| `HostState.swift` | `@MainActor ObservableObject` bridging engine state to SwiftUI |
| `PianoCamExtensionProvider.swift` | CMIO extension: sink stream + source stream + fallback frame generation |
| `PianoOverlay.swift` | Pure CG: 52 white keys + 36 black keys, velocity-scaled cyan glow, 3 pedals with brass gradients |
| `Config.swift` | `kFrameRate = 30`, `fixedCamWidth = 1280`, `fixedCamHeight = 720` |

## MIDI Input Details

`MIDIInput.swift` handles both MIDI 1.0 and MIDI 2.0 UMP. Events fire on CoreMIDI's background thread — dispatch to main queue before touching `PianoState`. Parsed events:
- Note on / off (velocity 0 treated as off)
- CC64 sustain, CC66 sostenuto, CC67 soft pedal
- CC123 all-notes-off

## Piano Overlay Layout

Bottom 30% of the 1280×720 frame:
```
4%  red felt strip
60% keys (white keys + black keys on top)
18% pedal area (soft / sostenuto / sustain)
```

White keys use a 3-stop gradient; active notes get velocity-scaled cyan glow (`intensity = max(0.25, velocity / 127)`). Black keys drawn on top of white keys.

## Overhead Camera (optional)

`PianoKeyboardAlignmentDetector` runs Vision black-key contour detection on a background queue, fits a parametric homography, and returns `screenPolygonForMIDINote(noteNumber:)` polygons for rendering MIDI highlights over real keys. Still needs real-world tuning for glossy pianos and hand-occlusion.

## CoreML Models

Models live in `Shared/` and are not committed to git (too large). To regenerate:

```bash
# Basic Pitch (polyphonic piano transcription)
pip install 'basic-pitch[onnx]' onnx2torch torch coremltools
python tools/export-basic-pitch-coreml.py
# Output: Shared/Models/BasicPitch.mlpackage

# Vocal isolator
python tools/export-vocal-isolator-coreml.py
```

## Entitlements

**Host app** (`PianoCam.entitlements`): app-sandbox, system-extension-install, camera, audio-input, user-selected files, app-groups.

**Extension** (`PianoCamExtension.entitlements`): app-sandbox, app-groups only.

App group ID is `$(TeamIdentifierPrefix)com.mayank.pianocam` — **no `group.` prefix** (critical; wrong prefix breaks IPC).

**Extension Info.plist** has a `CMIOExtension` dict but **no `NSExtension` dict** — adding `NSExtension` breaks discovery.

## Frame Pipeline

```
AVCaptureSession (real webcam)
    ↓ CMSampleBuffer
makeCompositeFrame() — CGContext 1280×720
    ├─ Draw webcam frame (top 70%)
    └─ Draw PianoOverlay (bottom 30%) — active notes from PianoState
         ↓
CVPixelBuffer → CMSampleBuffer
    ↓
CMSimpleQueueEnqueue(sinkQueue)
    ↓ (extension consumes)
consumeBuffer() → stream.send() → Zoom / QuickTime
```
