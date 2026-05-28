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
