//
//  PianoKeyboardAlignmentDetector.swift
//  PianoCam
//
//  Host-side overhead-camera alignment using Vision contours over black keys.
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Vision

final class PianoKeyboardAlignmentTracker {
    private let queue = DispatchQueue(label: "pianocam.keyboard-alignment", qos: .userInitiated)
    private let lock = NSLock()
    private let detector = PianoKeyboardAlignmentDetector()

    private var inFlight = false
    private var lastAttempt = Date.distantPast
    private var alignmentUnsafe: PianoKeyboardAlignment?

    var alignment: PianoKeyboardAlignment? {
        lock.lock(); defer { lock.unlock() }
        return alignmentUnsafe
    }

    func reset() {
        lock.lock()
        alignmentUnsafe = nil
        lock.unlock()
        lastAttempt = .distantPast
    }

    func submit(pixelBuffer: CVPixelBuffer,
                configuration: PianoKeyboardConfiguration,
                minimumInterval: TimeInterval = 0.75,
                completion: @escaping (PianoKeyboardAlignment?) -> Void) {
        let now = Date()
        guard !inFlight, now.timeIntervalSince(lastAttempt) >= minimumInterval else { return }
        inFlight = true
        lastAttempt = now

        queue.async { [weak self] in
            guard let self else { return }
            let result = try? self.detector.detect(pixelBuffer: pixelBuffer,
                                                   configuration: configuration)
            if let result, result.confidence >= 0.25 {
                self.lock.lock()
                self.alignmentUnsafe = result
                self.lock.unlock()
            }
            self.inFlight = false
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

final class PianoKeyboardAlignmentDetector {
    private struct Candidate {
        let center: CGPoint
        let bounds: CGRect
        let area: CGFloat
        /// Four corners of the contour in [TL, TR, BR, BL] order matching
        /// the model polygon, in our pixel coordinate system. Found by
        /// extreme-direction search on the contour's perimeter points so a
        /// rotated/perspective-warped key contributes its actual rotated
        /// corners — not the loose axis-aligned bounding box, which would
        /// strip away the rotation/perspective signal the homography needs.
        let corners: [CGPoint]
    }

    private struct Fit {
        let homography: PianoHomography
        let medianError: CGFloat
        let candidates: [Candidate]
    }

    func detect(pixelBuffer: CVPixelBuffer,
                configuration: PianoKeyboardConfiguration) throws -> PianoKeyboardAlignment? {
        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        let candidates = try detectBlackKeyCandidates(pixelBuffer: pixelBuffer,
                                                      frameSize: frameSize)
        guard candidates.count >= 7 else { return nil }

        let ordered = orderedAlongKeyboardAxis(candidates)
        guard let fit = bestFit(orderedCandidates: ordered,
                                configuration: configuration,
                                frameSize: frameSize) else { return nil }

        let confidence = confidenceScore(candidateCount: fit.candidates.count,
                                         medianError: fit.medianError,
                                         frameSize: frameSize)
        return PianoKeyboardAlignment(configuration: configuration,
                                      homography: fit.homography,
                                      frameSize: frameSize,
                                      confidence: confidence,
                                      medianErrorPixels: fit.medianError,
                                      matchedBlackKeyCount: fit.candidates.count)
    }

    private func detectBlackKeyCandidates(pixelBuffer: CVPixelBuffer,
                                          frameSize: CGSize) throws -> [Candidate] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.0
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 960

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first as? VNContoursObservation else { return [] }

        let contours = observation.topLevelContours
        let frameArea = max(1, frameSize.width * frameSize.height)
        var candidates: [Candidate] = []

        for contour in contours {
            let normalized = contour.normalizedPath.boundingBoxOfPath
            guard normalized.width > 0, normalized.height > 0 else { continue }

            let bounds = CGRect(x: normalized.minX * frameSize.width,
                                y: normalized.minY * frameSize.height,
                                width: normalized.width * frameSize.width,
                                height: normalized.height * frameSize.height)
            let area = bounds.width * bounds.height
            let areaFraction = area / frameArea
            let aspect = max(bounds.width / max(bounds.height, 1),
                             bounds.height / max(bounds.width, 1))

            guard areaFraction > 0.00008,
                  areaFraction < 0.035,
                  aspect > 1.35,
                  aspect < 12 else { continue }

            let corners = Self.cornersFromContour(contour, frameSize: frameSize)
            guard corners.count == 4 else { continue }
            candidates.append(Candidate(center: CGPoint(x: bounds.midX, y: bounds.midY),
                                        bounds: bounds,
                                        area: area,
                                        corners: corners))
        }

        return Array(candidates
            .sorted { $0.area > $1.area }
            .prefix(64))
    }

    private func orderedAlongKeyboardAxis(_ candidates: [Candidate]) -> [Candidate] {
        let mean = candidates.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.center.x, y: $0.y + $1.center.y)
        }
        let count = CGFloat(max(1, candidates.count))
        let center = CGPoint(x: mean.x / count, y: mean.y / count)

        var xx: CGFloat = 0
        var xy: CGFloat = 0
        var yy: CGFloat = 0
        for c in candidates {
            let dx = c.center.x - center.x
            let dy = c.center.y - center.y
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }

        let angle = 0.5 * atan2(2 * xy, xx - yy)
        var axis = CGPoint(x: cos(angle), y: sin(angle))
        if abs(axis.x) < 0.2 { axis = CGPoint(x: -axis.y, y: axis.x) }
        if axis.x < 0 { axis = CGPoint(x: -axis.x, y: -axis.y) }

        return candidates.sorted {
            projection($0.center, onto: axis) < projection($1.center, onto: axis)
        }
    }

    private func bestFit(orderedCandidates: [Candidate],
                         configuration: PianoKeyboardConfiguration,
                         frameSize: CGSize) -> Fit? {
        let geometry = PianoKeyboardGeometry(configuration: configuration)
        let modelBlackKeys = geometry.blackKeys
        guard modelBlackKeys.count >= 7 else { return nil }

        let usableCount = min(orderedCandidates.count, modelBlackKeys.count)
        guard usableCount >= 7 else { return nil }

        var best: Fit?
        let candidateWindows = candidateSlices(orderedCandidates, count: usableCount)

        for candidates in candidateWindows {
            for start in 0...(modelBlackKeys.count - candidates.count) {
                let modelSlice = Array(modelBlackKeys[start..<(start + candidates.count)])
                evaluate(modelSlice: modelSlice, candidates: candidates, reversed: false, best: &best)
                evaluate(modelSlice: modelSlice, candidates: candidates, reversed: true, best: &best)
            }
        }
        return best
    }

    private func candidateSlices(_ candidates: [Candidate], count: Int) -> [[Candidate]] {
        guard candidates.count > count else { return [candidates] }
        var slices: [[Candidate]] = []
        for start in 0...(candidates.count - count) {
            slices.append(Array(candidates[start..<(start + count)]))
        }
        return slices
    }

    private func evaluate(modelSlice: [PianoKeyGeometry],
                          candidates: [Candidate],
                          reversed: Bool,
                          best: inout Fit?) {
        // Use four corners per candidate instead of just the center. Black-key
        // model centers are all collinear in y (every modelCenter sits on
        // y = (blackFrontY + 1) / 2), which makes the homography normal-equations
        // matrix rank-deficient. The polygon corners span y = blackFrontY..1
        // in model space, giving the solver the second dimension of variation
        // it needs. We use the contour's actual corners (extreme-direction
        // points on the perimeter) rather than the axis-aligned bbox so the
        // homography sees the in-image rotation and perspective too.
        let orderedCandidates = reversed ? Array(candidates.reversed()) : candidates
        var observed: [CGPoint] = []
        var model: [CGPoint] = []
        observed.reserveCapacity(orderedCandidates.count * 4)
        model.reserveCapacity(orderedCandidates.count * 4)
        for (idx, key) in modelSlice.enumerated() {
            observed.append(contentsOf: orderedCandidates[idx].corners)
            model.append(contentsOf: key.modelPolygon)
        }
        guard let homography = PianoHomography.fit(modelPoints: model, imagePoints: observed) else { return }

        var errors: [CGFloat] = []
        errors.reserveCapacity(observed.count)
        for (m, observedPoint) in zip(model, observed) {
            let projected = homography.project(m)
            errors.append(hypot(projected.x - observedPoint.x,
                                projected.y - observedPoint.y))
        }
        errors.sort()
        let median = errors[errors.count / 2]
        let fit = Fit(homography: homography,
                      medianError: median,
                      candidates: orderedCandidates)
        if best == nil || fit.medianError < best!.medianError {
            best = fit
        }
    }

    private func confidenceScore(candidateCount: Int,
                                 medianError: CGFloat,
                                 frameSize: CGSize) -> Double {
        let countScore = min(1, Double(candidateCount) / 18.0)
        let scale = max(frameSize.width, frameSize.height)
        let errorScore = max(0, 1 - Double(medianError / max(1, scale)) / 0.018)
        return max(0, min(1, countScore * 0.45 + errorScore * 0.55))
    }

    private func projection(_ point: CGPoint, onto axis: CGPoint) -> CGFloat {
        point.x * axis.x + point.y * axis.y
    }

    /// Find the four corners of a contour by maximizing the four diagonal
    /// directions over its perimeter points. For both axis-aligned and
    /// rotated rectangles, the corners are extremes along these directions,
    /// so this works without an explicit rotated-rect fit.
    ///
    /// Vision normalized coords are bottom-origin; we scale them into our
    /// pixel space the same way `bounds` is built, which leaves the y-axis
    /// flipped relative to display. The corner ordering accounts for that
    /// flip so the result is [TL, TR, BR, BL] in display terms, matching
    /// the model polygon order (`PianoKeyGeometry.modelPolygon`).
    private static func cornersFromContour(_ contour: VNContour,
                                           frameSize: CGSize) -> [CGPoint] {
        let pts = contour.normalizedPoints
        guard !pts.isEmpty else { return [] }
        var tlIdx = 0, trIdx = 0, brIdx = 0, blIdx = 0
        var tlScore = -Float.infinity
        var trScore = -Float.infinity
        var brScore = -Float.infinity
        var blScore = -Float.infinity
        for (i, p) in pts.enumerated() {
            // In our (Vision-derived) pixel coords, larger y = top of
            // display. TL = small x, large y → max(y - x).
            let tl = p.y - p.x
            let tr = p.x + p.y
            let br = p.x - p.y
            let bl = -p.x - p.y
            if tl > tlScore { tlScore = tl; tlIdx = i }
            if tr > trScore { trScore = tr; trIdx = i }
            if br > brScore { brScore = br; brIdx = i }
            if bl > blScore { blScore = bl; blIdx = i }
        }
        let w = frameSize.width
        let h = frameSize.height
        func scale(_ idx: Int) -> CGPoint {
            CGPoint(x: CGFloat(pts[idx].x) * w, y: CGFloat(pts[idx].y) * h)
        }
        return [scale(tlIdx), scale(trIdx), scale(brIdx), scale(blIdx)]
    }
}
