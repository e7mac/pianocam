# Overhead Camera Simulator (dev-only)

**Date:** 2026-05-27
**Status:** Design approved, awaiting implementation plan
**Scope:** PianoCam macOS app — `PianoKeyboardAlignmentDetector` development aid

## Problem

The overhead-piano alignment feature in PianoCam reads frames from a second
physical camera (typically a Continuity Camera aimed down at a keyboard),
detects black-key contours via Vision, and fits a homography. Iterating on the
detector currently requires:

- A real piano
- A second camera mounted overhead and powered
- A way to reproduce specific failure cases (glossy keys, hand occlusion,
  oblique angles, partial keyboards, etc.)

This is slow and non-deterministic. We want to drive the same `CVPixelBuffer`
path with static images from disk so the detector can be developed and
regression-tested without a physical rig.

## Goals

1. Feed the existing `PianoKeyboardAlignmentTracker.submit(pixelBuffer:...)`
   from a disk-backed image instead of `AVCaptureSession`, with zero changes to
   the detector.
2. Support a single image file *or* a directory of images. A directory cycles
   so a curated set of test photos can be evaluated in one session.
3. Stay dev-only — no shipping UI surface; activation is via launch
   environment variable.
4. Be easy to remove later (single env-var check, one new file, one small
   protocol).

## Non-goals

- Recorded video playback
- Procedurally rendered piano images
- Runtime UI toggle between live and simulated sources
- Synthetic MIDI input (separate feature if needed)
- Persisting per-image detection results to disk

## Architecture

### Source abstraction

Introduce a minimal protocol that both the live camera and the simulator
conform to:

```swift
protocol OverheadFrameSource: AnyObject {
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    func start()
    func stop()
    func setDevice(_ device: AVCaptureDevice?)
    func setPreferredZoomFactor(_ factor: CGFloat?)
}
```

`CameraCapture` already exposes exactly this surface and conforms with no
behavior change. `SimulatedOverheadSource` implements `start/stop` and
ignores `setDevice` / `setPreferredZoomFactor`.

`ViewController.overheadCameraCapture` becomes typed as
`any OverheadFrameSource`. The webcam path (`cameraCapture`) is unaffected —
only the overhead source is abstracted.

### Activation

At `ViewController` startup, read `ProcessInfo.processInfo.environment`:

- `PIANOCAM_OVERHEAD_SIM_IMAGE` — path to a file OR directory.
  - If unset → use `CameraCapture` (current behavior).
  - If set and points to a regular file with extension `.jpg/.jpeg/.png` →
    use `SimulatedOverheadSource` with that single image.
  - If set and points to a directory → enumerate `.jpg/.jpeg/.png` files
    (non-recursive, sorted by name) and cycle.
  - If set but invalid → log a clear error and fall back to `CameraCapture`.

### SimulatedOverheadSource

New file: `PianoCam/SimulatedOverheadSource.swift` (~100 lines).

Responsibilities:

1. On `init(path:)`, resolve the path to a list of image URLs.
2. On `start()`:
   - Lazily decode the current image to a BGRA `CVPixelBuffer` (matches
     `CameraCapture`'s `kCVPixelFormatType_32BGRA` output).
   - Start a 10 Hz timer that calls `onFrame?(buffer)` on a serial dispatch
     queue (mirroring `CameraCapture`'s capture queue semantics).
   - If cycling: advance to the next image every 3 seconds. The alignment
     tracker rate-limits to 0.75 s between attempts, so 3 s gives ~3–4
     detection attempts per image — enough to see whether it locked on.
3. On `stop()`, invalidate timer and drop the buffer.
4. `setDevice` / `setPreferredZoomFactor`: no-ops (logged once at debug level
   so it's clear they were ignored).

Pixel-buffer creation uses `CVPixelBufferCreate` + `CGContext` draw of the
`NSImage` into BGRA at the image's native pixel dimensions. Detector is
resolution-agnostic.

### Control panel

`ControlPanel.swift` shows the existing overhead-camera picker only when
`hostState.overheadSourceIsSimulated == false`. When simulated, it shows a
disabled label:

```
Source: Simulated — <basename>  (n images)
```

This is a single line of read-only UI; no interactive surface.

## Data flow

```
ENV var set?
   │
   ├─ no ──► CameraCapture ──► onFrame ──► latestOverheadFrame ──► alignmentTracker
   │
   └─ yes ─► SimulatedOverheadSource ──► onFrame ──► latestOverheadFrame ──► alignmentTracker
              (timer-driven, optional cycling)
```

Everything downstream of `onFrame` is unchanged. The detector receives the
same shape and format of `CVPixelBuffer` it would from the live camera.

## Files

| Change | File | Lines |
|---|---|---|
| New | `PianoCam/SimulatedOverheadSource.swift` | ~100 |
| New | (none) | — |
| Edit | `PianoCam/CameraCapture.swift` | add `: OverheadFrameSource` conformance, no logic change |
| Edit | `PianoCam/ViewController.swift` | typed swap + env-var dispatch (~15 lines) |
| Edit | `PianoCam/ControlPanel.swift` | conditional read-only label (~5 lines) |
| Edit | `PianoCam/HostState.swift` | one `@Published var overheadSourceIsSimulated` + label (~3 lines) |
| Edit | `PianoCam.xcodeproj` | add new file to `PianoCam` target via `tools/add_target_file.rb` |

## Error handling

- Invalid path → `NSLog` an error, fall back to live `CameraCapture`. App
  still works.
- Image decode failure → `NSLog`, skip that image (in cycling mode) or
  abort and fall back (in single-image mode).
- Zero images in directory → log, fall back to live.

No alerts, no crashes, no shipping-user-visible behavior.

## Testing

Manual:

1. Launch with no env var → overhead picker behaves as before.
2. Launch with `PIANOCAM_OVERHEAD_SIM_IMAGE=~/Desktop/piano.jpg` → toggle
   overhead-piano on, see the image in the bottom band, watch the detector
   attempt alignment.
3. Launch with `PIANOCAM_OVERHEAD_SIM_IMAGE=~/Desktop/piano_set/` → confirm
   cycling, status updates as different images load.
4. Launch with invalid path → confirm graceful fall-back to live camera.

No automated tests — this is dev-only scaffolding.

## Removal

Delete the file, revert the protocol back to direct `CameraCapture` typing,
remove the env-var check. No data migration, no user-visible change.
