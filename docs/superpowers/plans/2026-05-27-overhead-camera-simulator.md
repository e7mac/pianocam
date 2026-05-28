# Overhead Camera Simulator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive `PianoKeyboardAlignmentDetector` from static images on disk so the overhead-camera alignment feature can be developed and regression-tested without a physical second-camera rig.

**Architecture:** Introduce a tiny `OverheadFrameSource` protocol that the existing `CameraCapture` conforms to. Add a parallel `SimulatedOverheadSource` that loads images from a path (file or directory), decodes them to BGRA `CVPixelBuffer`s, and fires `onFrame` on a timer. `ViewController` picks one or the other at startup based on the `PIANOCAM_OVERHEAD_SIM_IMAGE` env var. Dev-only — no shipping UI surface beyond a read-only "Simulated" label when active.

**Tech Stack:** Swift 6, AppKit (`NSImage`), CoreVideo (`CVPixelBufferCreate`, `CGContext`), AVFoundation (existing camera path), SwiftUI (control panel).

**Testing approach:** No unit-test infrastructure exists for the PianoCam host app. Verification is `xcodebuild build` for compilation between tasks, and an end-of-plan manual run with a real piano photo. This is documented and intentional — adding XCTest for a dev-only tool is out of scope.

**Spec reference:** `docs/superpowers/specs/2026-05-27-overhead-camera-simulator-design.md`

---

## File Structure

| Path | Role |
|---|---|
| `PianoCam/SimulatedOverheadSource.swift` | NEW. Disk-backed overhead frame producer. |
| `PianoCam/CameraCapture.swift` | EDIT. Add `OverheadFrameSource` conformance (no behavior change). |
| `PianoCam/OverheadFrameSource.swift` | NEW. Protocol abstracting overhead frame producers. |
| `PianoCam/ViewController.swift` | EDIT. Swap typed ivar to protocol; dispatch on env var at init. |
| `PianoCam/HostState.swift` | EDIT. Add `overheadSourceLabel: String?` published var. |
| `PianoCam/ControlPanel.swift` | EDIT. Render disabled "Simulated — name" label when set. |
| `PianoCam.xcodeproj/project.pbxproj` | EDIT (via `tools/add_target_file.rb`). Register the two new files in the `PianoCam` target. |

---

## Task 1: Define `OverheadFrameSource` protocol and conform `CameraCapture`

**Files:**
- Create: `PianoCam/OverheadFrameSource.swift`
- Modify: `PianoCam/CameraCapture.swift`

- [ ] **Step 1: Create the protocol file**

Write `PianoCam/OverheadFrameSource.swift`:

```swift
//
//  OverheadFrameSource.swift
//  PianoCam
//
//  Common interface for objects that produce overhead-camera frames.
//  Conformed to by `CameraCapture` (live AVCaptureSession) and
//  `SimulatedOverheadSource` (disk-backed dev tool).
//

import AVFoundation
import CoreVideo

protocol OverheadFrameSource: AnyObject {
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    func start()
    func stop()
    func setDevice(_ device: AVCaptureDevice?)
    func setPreferredZoomFactor(_ factor: CGFloat?)
}
```

- [ ] **Step 2: Conform `CameraCapture` to the protocol**

In `PianoCam/CameraCapture.swift`, change the class declaration:

```swift
final class CameraCapture: NSObject {
```

to:

```swift
final class CameraCapture: NSObject, OverheadFrameSource {
```

No method body changes — `CameraCapture` already has the required surface.

- [ ] **Step 3: Register the new file in the Xcode project**

Run from the repo root:

```bash
ruby tools/add_target_file.rb PianoCam.xcodeproj PianoCam PianoCam/OverheadFrameSource.swift PianoCam
```

Expected output: a line confirming the file was added to the `PianoCam` target.

- [ ] **Step 4: Build to verify compilation**

```bash
xcodebuild -project PianoCam.xcodeproj -scheme PianoCam -configuration Debug build -quiet
```

Expected: build succeeds. If `add_target_file.rb` failed silently, the build will error with "Cannot find type 'OverheadFrameSource'" — re-run the script with verbose output.

- [ ] **Step 5: Commit**

```bash
git add PianoCam/OverheadFrameSource.swift PianoCam/CameraCapture.swift PianoCam.xcodeproj/project.pbxproj
git commit -m "Add OverheadFrameSource protocol for swappable overhead sources"
```

---

## Task 2: Implement `SimulatedOverheadSource` (single file mode)

**Files:**
- Create: `PianoCam/SimulatedOverheadSource.swift`

- [ ] **Step 1: Create the file with single-image support**

Write `PianoCam/SimulatedOverheadSource.swift`:

```swift
//
//  SimulatedOverheadSource.swift
//  PianoCam
//
//  Dev-only overhead frame producer that reads JPEG/PNG files from disk
//  and emits them as BGRA CVPixelBuffers, mirroring CameraCapture's output
//  format. Activated via the PIANOCAM_OVERHEAD_SIM_IMAGE environment
//  variable at app launch. Not exposed in shipping UI.
//

import AppKit
import AVFoundation
import CoreVideo
import Foundation

final class SimulatedOverheadSource: NSObject, OverheadFrameSource {
    private let queue = DispatchQueue(label: "pianocam.simulated-overhead", qos: .userInteractive)
    private let imageURLs: [URL]
    private var currentIndex: Int = 0
    private var currentBuffer: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private let frameInterval: TimeInterval = 0.1   // 10 Hz
    private let cycleInterval: TimeInterval = 3.0   // advance image every 3s
    private var lastCycleAt: Date = .distantPast
    private var isRunning = false

    var onFrame: ((CVPixelBuffer) -> Void)?

    /// Source label suitable for UI display (basename of the path).
    let label: String

    /// Returns nil if no images were resolvable from the path.
    init?(path: String) {
        let urls = Self.resolveImageURLs(path: path)
        guard !urls.isEmpty else {
            NSLog("PianoCam: SimulatedOverheadSource found no images at \(path)")
            return nil
        }
        self.imageURLs = urls
        let url = URL(fileURLWithPath: path)
        if urls.count == 1 {
            self.label = url.lastPathComponent
        } else {
            self.label = "\(url.lastPathComponent) (\(urls.count) images)"
        }
        super.init()
    }

    static func resolveImageURLs(path: String) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: expanded, isDirectory: &isDir) else { return [] }
        let url = URL(fileURLWithPath: expanded)
        let allowed: Set<String> = ["jpg", "jpeg", "png"]

        if isDir.boolValue {
            let contents = (try? fm.contentsOfDirectory(at: url,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? []
            return contents
                .filter { allowed.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            return allowed.contains(url.pathExtension.lowercased()) ? [url] : []
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.currentIndex = 0
            self.lastCycleAt = Date()
            self.loadCurrentImage()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: self.frameInterval, leeway: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.currentBuffer = nil
            self.isRunning = false
        }
    }

    func setDevice(_ device: AVCaptureDevice?) {
        // Intentional no-op. The simulator has no AVCaptureDevice.
    }

    func setPreferredZoomFactor(_ factor: CGFloat?) {
        // Intentional no-op.
    }

    private func tick() {
        if imageURLs.count > 1,
           Date().timeIntervalSince(lastCycleAt) >= cycleInterval {
            currentIndex = (currentIndex + 1) % imageURLs.count
            lastCycleAt = Date()
            loadCurrentImage()
        }
        if let buffer = currentBuffer {
            onFrame?(buffer)
        }
    }

    private func loadCurrentImage() {
        let url = imageURLs[currentIndex]
        guard let image = NSImage(contentsOf: url),
              let buffer = Self.bgraPixelBuffer(from: image) else {
            NSLog("PianoCam: SimulatedOverheadSource failed to decode \(url.lastPathComponent)")
            currentBuffer = nil
            return
        }
        currentBuffer = buffer
        NSLog("PianoCam: SimulatedOverheadSource loaded \(url.lastPathComponent) (\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)))")
    }

    static func bgraPixelBuffer(from image: NSImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
```

Notes for the implementer:
- The class is `final` and inherits `NSObject` only to be compatible with any potential KVC/AVFoundation interop — same as `CameraCapture`.
- `bgraPixelBuffer(from:)` uses `premultipliedFirst` + `byteOrder32Little` which produces a BGRA layout matching `kCVPixelFormatType_32BGRA`.
- The same cached `CVPixelBuffer` is emitted every tick until the image cycles. Decoding once per image keeps the timer cheap.
- All mutable state is touched only on `queue`. `onFrame` is invoked from `queue` — same threading contract as `CameraCapture`.

- [ ] **Step 2: Register the new file in the Xcode project**

```bash
ruby tools/add_target_file.rb PianoCam.xcodeproj PianoCam PianoCam/SimulatedOverheadSource.swift PianoCam
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project PianoCam.xcodeproj -scheme PianoCam -configuration Debug build -quiet
```

Expected: build succeeds. The class isn't wired up yet — wiring happens in Task 3.

- [ ] **Step 4: Commit**

```bash
git add PianoCam/SimulatedOverheadSource.swift PianoCam.xcodeproj/project.pbxproj
git commit -m "Add SimulatedOverheadSource: disk-backed overhead frame producer"
```

---

## Task 3: Wire env-var dispatch into `ViewController`

**Files:**
- Modify: `PianoCam/ViewController.swift`

- [ ] **Step 1: Change the `overheadCameraCapture` declaration to a protocol**

Locate this line near the top of `ViewController` (~line 23):

```swift
    private let overheadCameraCapture = CameraCapture()
```

Replace with:

```swift
    private let overheadCameraCapture: any OverheadFrameSource = ViewController.makeOverheadSource()
```

Then add a static factory near the other private helpers in the class. Search for a good spot (e.g., right after the ivar block, before `func activateCamera()`). Insert:

```swift
    /// Picks the overhead-camera source for this run. Reads
    /// PIANOCAM_OVERHEAD_SIM_IMAGE; if set and resolvable, returns a
    /// SimulatedOverheadSource. Otherwise returns a real CameraCapture.
    private static func makeOverheadSource() -> any OverheadFrameSource {
        if let path = ProcessInfo.processInfo.environment["PIANOCAM_OVERHEAD_SIM_IMAGE"],
           !path.isEmpty {
            if let sim = SimulatedOverheadSource(path: path) {
                NSLog("PianoCam: using simulated overhead source from \(path)")
                return sim
            }
            NSLog("PianoCam: PIANOCAM_OVERHEAD_SIM_IMAGE set but unresolvable, falling back to live camera")
        }
        return CameraCapture()
    }

    private var simulatedOverheadLabel: String? {
        (overheadCameraCapture as? SimulatedOverheadSource)?.label
    }
```

- [ ] **Step 2: Build to verify the protocol typing compiles**

```bash
xcodebuild -project PianoCam.xcodeproj -scheme PianoCam -configuration Debug build -quiet
```

Expected: build succeeds. All existing call sites already use only methods on the protocol (`setDevice`, `setPreferredZoomFactor`, `start`, `stop`, `onFrame`), so no further changes are needed in `ViewController`.

If the build fails citing one of the call sites, inspect the call — it may be using a method not yet on the protocol. Add the missing method to the protocol and to both implementations (no-op on `SimulatedOverheadSource`).

- [ ] **Step 3: Commit**

```bash
git add PianoCam/ViewController.swift
git commit -m "Dispatch overhead source via env var in ViewController"
```

---

## Task 4: Expose the simulated label in `HostState` and `ControlPanel`

**Files:**
- Modify: `PianoCam/HostState.swift`
- Modify: `PianoCam/ControlPanel.swift`
- Modify: `PianoCam/ViewController.swift`

- [ ] **Step 1: Add the published var to `HostState`**

In `PianoCam/HostState.swift`, find the overhead block (around line 38–43). Add a new line directly after `@Published var overheadAlignmentStatus`:

```swift
    /// When non-nil, the overhead source is the dev-only image simulator;
    /// the camera picker should be hidden and this label shown instead.
    @Published var simulatedOverheadLabel: String? = nil
```

- [ ] **Step 2: Set it from `ViewController` after `installSwiftUIPanel()`**

In `PianoCam/ViewController.swift`, find where the SwiftUI panel is installed (`installSwiftUIPanel()`). After the line that creates `actions = HostActions(...)` but before the function returns — or simply at the end of `viewDidLoad`/equivalent setup — add:

```swift
        hostState.simulatedOverheadLabel = simulatedOverheadLabel
```

If you're unsure where, the safe spot is at the very end of the function where camera enumeration also happens (search for `hostState.cameras = CameraCapture.availableDevices`) and add the line immediately after.

- [ ] **Step 3: Render the label in `ControlPanel`**

In `PianoCam/ControlPanel.swift`, find the `overheadControls` view (around line 263). Replace the existing camera picker block:

```swift
            Picker("", selection: overheadCameraBinding) {
                if state.cameras.isEmpty {
                    Text("No cameras found").tag(String?.none)
                }
                ForEach(state.cameras, id: \.uniqueID) { d in
                    Text(d.localizedName).tag(String?.some(d.uniqueID))
                }
            }
            .labelsHidden()
            .frame(width: 260)
            .disabled(!state.overheadKeyboardEnabled)
```

with:

```swift
            if let simLabel = state.simulatedOverheadLabel {
                Text("Simulated — \(simLabel)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
            } else {
                Picker("", selection: overheadCameraBinding) {
                    if state.cameras.isEmpty {
                        Text("No cameras found").tag(String?.none)
                    }
                    ForEach(state.cameras, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(String?.some(d.uniqueID))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                .disabled(!state.overheadKeyboardEnabled)
            }
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -project PianoCam.xcodeproj -scheme PianoCam -configuration Debug build -quiet
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add PianoCam/HostState.swift PianoCam/ControlPanel.swift PianoCam/ViewController.swift
git commit -m "Show simulated-overhead label in the control panel"
```

---

## Task 5: Manual verification

This task has no code changes — it's the run-the-app step that proves the feature works. Capture results in your final report.

- [ ] **Step 1: Confirm live-camera path is unbroken**

```bash
xcodebuild -project PianoCam.xcodeproj -scheme PianoCam -configuration Debug build -quiet
```

Then run the app (in Xcode or via the produced `PianoCam.app`). Toggle **Overhead piano** on. With no env var set, the camera picker should appear as before and behave normally. Note in the report whether the picker rendered and was selectable.

- [ ] **Step 2: Find or create a test image**

Use any top-down photo of a piano keyboard. If you don't have one, an internet image of "overhead piano keyboard" saved to `~/Desktop/test-piano.jpg` is fine for first-pass detection.

- [ ] **Step 3: Run with `PIANOCAM_OVERHEAD_SIM_IMAGE` pointing to a single image**

From a terminal:

```bash
PIANOCAM_OVERHEAD_SIM_IMAGE=~/Desktop/test-piano.jpg \
  open -W /Applications/PianoCam.app
```

(Or in Xcode: Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables → add `PIANOCAM_OVERHEAD_SIM_IMAGE` with the path, then Run.)

Toggle **Overhead piano** on. Expected:
- The camera picker is replaced by `Simulated — test-piano.jpg`.
- The bottom band of the composite frame shows the image you supplied.
- `overheadAlignmentStatus` updates within ~1s, either with a confidence score or "Searching for black keys".

Capture the alignment confidence and status text in the report.

- [ ] **Step 4: Run with a directory of images**

Create a directory with 2–3 top-down piano images, e.g. `~/Desktop/piano-set/`. Launch with:

```bash
PIANOCAM_OVERHEAD_SIM_IMAGE=~/Desktop/piano-set/ \
  open -W /Applications/PianoCam.app
```

Expected:
- Label reads `Simulated — piano-set (3 images)`.
- The image in the bottom band changes every ~3s.
- The alignment status changes per image (confidence shifts as different photos are evaluated).

- [ ] **Step 5: Run with an invalid path**

```bash
PIANOCAM_OVERHEAD_SIM_IMAGE=/nonexistent/path.jpg \
  open -W /Applications/PianoCam.app
```

Expected:
- App launches normally.
- A line appears in `Console.app` (filter on "PianoCam"): `PIANOCAM_OVERHEAD_SIM_IMAGE set but unresolvable, falling back to live camera`.
- The overhead picker behaves as in Step 1 (live cameras listed).

- [ ] **Step 6: Final commit if any cleanup was needed**

If the manual steps surfaced any issues that required a code change (e.g., the label binding wasn't set, or the picker didn't hide), commit those fixes with a clear message and re-run the relevant manual step.

If nothing changed, no commit needed.

---

## Self-review notes

Run after writing all tasks:

- Spec coverage: every numbered Goal in the spec maps to a task (1–4 = Goals 1, 4, 3, 3; 5 = Goal 2 verification).
- Placeholder scan: no TBD/TODO; every code block is complete.
- Type consistency: `OverheadFrameSource` is the same name everywhere; `simulatedOverheadLabel` matches between `HostState` and `ControlPanel`; `SimulatedOverheadSource.label` is the property accessed in `ViewController.simulatedOverheadLabel`.
- Edge case: the env var is read once at static init via `ViewController.makeOverheadSource()`. Changing the env var requires an app relaunch — that's intentional and matches the spec.
