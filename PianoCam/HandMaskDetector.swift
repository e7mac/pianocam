//
//  HandMaskDetector.swift
//  PianoCam
//
//  Detects hands in the overhead frame using
//  VNDetectHumanHandPoseRequest, returns a CGPath that bounds them so
//  the alignment overlay can erase itself behind the hands. The MIDI
//  pipeline already tells us which keys are pressed; the mask is purely
//  cosmetic — a slightly-dilated hull around the visible fingers is
//  enough to make the overlay read as "keys under hands" instead of
//  "keys over hands".
//

import CoreGraphics
import CoreVideo
import Foundation
import Vision

final class HandMaskDetector {
    private let queue = DispatchQueue(label: "pianocam.hand-mask", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight = false
    private var lastAttempt = Date.distantPast

    /// Latest computed mask in pixel-buffer coordinates. The renderer
    /// scales it into the composite the same way the overhead frame is
    /// scaled.
    private var maskUnsafe: CGPath?
    private var maskFrameSize = CGSize.zero

    var mask: (path: CGPath, frameSize: CGSize)? {
        lock.lock(); defer { lock.unlock() }
        guard let m = maskUnsafe else { return nil }
        return (m, maskFrameSize)
    }

    func reset() {
        lock.lock()
        maskUnsafe = nil
        lock.unlock()
        lastAttempt = .distantPast
    }

    /// Submit a frame. Runs at most one detection at a time, throttled
    /// to `minimumInterval` between attempts. Runs in parallel with the
    /// alignment detector; the two share nothing.
    func submit(pixelBuffer: CVPixelBuffer,
                minimumInterval: TimeInterval = 0.15) {
        let now = Date()
        guard !inFlight, now.timeIntervalSince(lastAttempt) >= minimumInterval else { return }
        inFlight = true
        lastAttempt = now

        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }

            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 2
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: .up,
                                                options: [:])
            do {
                try handler.perform([request])
            } catch {
                return
            }
            guard let observations = request.results, !observations.isEmpty else {
                self.lock.lock(); self.maskUnsafe = nil; self.lock.unlock()
                return
            }

            let path = Self.buildMask(observations: observations,
                                       frameSize: frameSize)
            self.lock.lock()
            self.maskUnsafe = path
            self.maskFrameSize = frameSize
            self.lock.unlock()
        }
    }

    /// Build a single CGPath that unions the convex hulls of each hand's
    /// landmark cloud, with a small radial dilation so the overlay is
    /// hidden by a buffer around the fingers rather than tightly tracing
    /// them (which looks jittery on movement).
    private static func buildMask(observations: [VNHumanHandPoseObservation],
                                  frameSize: CGSize) -> CGPath? {
        let path = CGMutablePath()
        var any = false
        for obs in observations {
            // Collect every landmark with reasonable confidence.
            var points: [CGPoint] = []
            if let allPoints = try? obs.recognizedPoints(.all) {
                for (_, vp) in allPoints where vp.confidence > 0.3 {
                    // Vision normalized coords are bottom-origin. Convert
                    // to top-origin pixel space so the renderer can scale
                    // by the same transform it uses for the overhead frame.
                    let px = vp.location.x * frameSize.width
                    let py = (1 - vp.location.y) * frameSize.height
                    points.append(CGPoint(x: px, y: py))
                }
            }
            if points.count < 3 { continue }
            let hull = convexHull(points)
            // Dilate radially around the centroid. ~6% of the long edge
            // is enough to cover the back of the hand and a generous
            // finger margin without bleeding into the rest of the scene.
            let cx = hull.reduce(0) { $0 + $1.x } / CGFloat(hull.count)
            let cy = hull.reduce(0) { $0 + $1.y } / CGFloat(hull.count)
            let dilation = max(frameSize.width, frameSize.height) * 0.06
            let dilated = hull.map { p -> CGPoint in
                let dx = p.x - cx
                let dy = p.y - cy
                let len = hypot(dx, dy)
                guard len > 0.001 else { return p }
                return CGPoint(x: p.x + dx / len * dilation,
                               y: p.y + dy / len * dilation)
            }
            path.move(to: dilated[0])
            for p in dilated.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
            any = true
        }
        return any ? path : nil
    }

    /// Andrew's monotone chain convex hull. Points must be 2D, returns
    /// in counter-clockwise order.
    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted {
            $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y)
        }
        guard sorted.count > 2 else { return sorted }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
