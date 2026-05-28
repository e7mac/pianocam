//
//  SimulatedCameraSource.swift
//  PianoCam
//
//  Synthetic "overhead piano" video stream for developing the auto-aligner
//  without needing a real camera + real piano setup.
//
//  Renders the existing PianoOverlay keyboard into a flat image, applies a
//  parametric perspective warp (rotation, keystone, pan, scale), and emits
//  CVPixelBuffers through the same onFrame callback that CameraCapture uses.
//  ViewController treats it as a drop-in replacement for the real camera.
//
//  The warp parameters are also exposed as the "ground truth" homography that
//  an aligner has to recover — the four destination corners are published on
//  every frame.
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation

final class SimulatedCameraSource {
    struct WarpParams: Equatable {
        /// In-plane rotation in degrees (roll).
        var rotationDegrees: CGFloat = 0
        /// Keystone effect: top of keyboard narrower (>0) or wider (<0) than
        /// bottom. Range roughly -0.6 ... 0.6.
        var keystone: CGFloat = 0.25
        /// Horizontal skew (yaw) — left edge longer (>0) or right edge longer
        /// (<0). Range roughly -0.4 ... 0.4.
        var skew: CGFloat = 0
        /// Pan offset as a fraction of frame size, -1 ... 1.
        var panX: CGFloat = 0
        var panY: CGFloat = 0
        /// Uniform scale around 1.0. Range roughly 0.5 ... 1.5.
        var scale: CGFloat = 0.85
    }

    /// Latest computed destination corners (output-image coordinates,
    /// top-left origin). The future aligner can use this as ground truth.
    struct Corners: Equatable {
        var topLeft: CGPoint
        var topRight: CGPoint
        var bottomLeft: CGPoint
        var bottomRight: CGPoint
    }

    /// Called on the render queue with each generated frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called whenever the warp params change, with the resulting corners.
    var onCorners: ((Corners) -> Void)?

    /// Mutate via `setParams` so we can keep the cached keyboard image valid.
    private(set) var params = WarpParams()

    private let outWidth: Int
    private let outHeight: Int
    private let fps: Double
    private let queue = DispatchQueue(label: "pianocam.simcam", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var timer: DispatchSourceTimer?
    private var cachedKeyboard: CIImage?
    private let keyboardWidth = 1280
    private let keyboardHeight = 220

    init(width: Int = 1280, height: Int = 720, fps: Double = 30) {
        self.outWidth = width
        self.outHeight = height
        self.fps = fps
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0 / self.fps)
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func setParams(_ p: WarpParams) {
        queue.async { [weak self] in
            guard let self else { return }
            self.params = p
            self.publishCorners()
        }
    }

    /// Ground-truth corners for whatever `params` is currently set to. The
    /// aligner consumes these to score how close its recovered homography is.
    var currentCorners: Corners {
        computeCorners()
    }

    // MARK: - Rendering

    private func tick() {
        guard let pb = renderFrame() else { return }
        onFrame?(pb)
    }

    private func keyboardImage() -> CIImage? {
        if let cached = cachedKeyboard { return cached }
        let w = keyboardWidth, h = keyboardHeight
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue
                   | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: bitmap) else {
            return nil
        }
        // Subtle felt strip above the keys to give the aligner a hint
        // where the top of the keyboard is.
        let feltH = max(2, h / 25)
        ctx.setFillColor(CGColor(red: 0.40, green: 0.05, blue: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - feltH, width: w, height: feltH))
        PianoOverlay.drawKeyboardOnly(
            into: ctx,
            rect: CGRect(x: 0, y: 0, width: w, height: h - feltH)
        )
        guard let cg = ctx.makeImage() else { return nil }
        let ci = CIImage(cgImage: cg)
        cachedKeyboard = ci
        return ci
    }

    private func renderFrame() -> CVPixelBuffer? {
        guard let kb = keyboardImage() else { return nil }
        let corners = computeCorners()

        // CoreImage uses lower-left origin; convert from top-left image coords.
        let h = CGFloat(outHeight)
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }

        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return nil }
        filter.setValue(kb, forKey: kCIInputImageKey)
        // Source image's top-left corner maps to the output's top-left, etc.
        // The keyboard CGImage was built with CG's bottom-left origin, so its
        // "top" in image-space is at y = keyboardHeight. We flip both image and
        // output corners through the same axis flip so the mapping lines up.
        filter.setValue(CIVector(cgPoint: flip(corners.topLeft)),     forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: flip(corners.topRight)),    forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: flip(corners.bottomLeft)),  forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: flip(corners.bottomRight)), forKey: "inputBottomRight")
        guard let warped = filter.outputImage else { return nil }

        // Dark grey background so the unrendered region looks like a real
        // tabletop, not bright magenta — and so the aligner has clear contrast
        // against the white keys.
        let bg = CIImage(color: CIColor(red: 0.12, green: 0.10, blue: 0.10))
            .cropped(to: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        let composed = warped.composited(over: bg)
            .cropped(to: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))

        var pb: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, outWidth, outHeight,
                                  kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        ciContext.render(composed, to: buffer)
        return buffer
    }

    private func publishCorners() {
        onCorners?(computeCorners())
    }

    /// Computes the four output-image corners (top-left origin) the warped
    /// keyboard image should land on.
    private func computeCorners() -> Corners {
        let cx = CGFloat(outWidth)  * 0.5 + params.panX * CGFloat(outWidth)  * 0.3
        let cy = CGFloat(outHeight) * 0.5 + params.panY * CGFloat(outHeight) * 0.3
        // "Natural" placement: keyboard fills 80% of the width, plus a
        // height set by the keyboard's aspect ratio.
        let aspect = CGFloat(keyboardWidth) / CGFloat(keyboardHeight)
        let halfW = CGFloat(outWidth) * 0.40 * params.scale
        let halfH = halfW / aspect

        let topShrink = max(0.2, 1 - params.keystone)
        let botShrink = max(0.2, 1 + params.keystone)
        let leftStretch  = max(0.2, 1 - params.skew)
        let rightStretch = max(0.2, 1 + params.skew)

        let r = params.rotationDegrees * .pi / 180
        let cosR = cos(r), sinR = sin(r)

        func project(dx: CGFloat, dy: CGFloat) -> CGPoint {
            let xR = dx * cosR - dy * sinR
            let yR = dx * sinR + dy * cosR
            return CGPoint(x: cx + xR, y: cy + yR)
        }

        return Corners(
            topLeft:     project(dx: -halfW * topShrink * leftStretch,  dy: -halfH * leftStretch),
            topRight:    project(dx:  halfW * topShrink * rightStretch, dy: -halfH * rightStretch),
            bottomLeft:  project(dx: -halfW * botShrink * leftStretch,  dy:  halfH * leftStretch),
            bottomRight: project(dx:  halfW * botShrink * rightStretch, dy:  halfH * rightStretch)
        )
    }
}
