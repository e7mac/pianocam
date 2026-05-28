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

    /// Which key class to extract from the image. Different overhead lighting
    /// conditions favor different classes:
    ///   - black: clean on light/white backgrounds (rendered diagrams, light
    ///            backdrop photos). Fails when black keys are connected to a
    ///            dark backdrop through the gaps between whites.
    ///   - white: clean on dark backgrounds (most piano photos). Fails when
    ///            white keys merge into one large light region with no
    ///            interior boundaries (e.g. CG-rendered keyboards without
    ///            gaps between white keys).
    private enum KeyKind { case black, white }

    func detect(pixelBuffer: CVPixelBuffer,
                configuration: PianoKeyboardConfiguration) throws -> PianoKeyboardAlignment? {
        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        // Try both key classes and keep the higher-confidence result. The
        // overhead of the second pass is small relative to one VNDetectContours
        // call, and the two classes are complementary across the lighting
        // conditions we see in practice.
        let attempts: [PianoKeyboardAlignment?] = [
            try? attempt(kind: .black,
                         pixelBuffer: pixelBuffer,
                         configuration: configuration,
                         frameSize: frameSize),
            try? attempt(kind: .white,
                         pixelBuffer: pixelBuffer,
                         configuration: configuration,
                         frameSize: frameSize)
        ]
        return attempts.compactMap { $0 }.max { $0.confidence < $1.confidence }
    }

    private func attempt(kind: KeyKind,
                         pixelBuffer: CVPixelBuffer,
                         configuration: PianoKeyboardConfiguration,
                         frameSize: CGSize) throws -> PianoKeyboardAlignment? {
        let raw = try detectCandidates(kind: kind,
                                       pixelBuffer: pixelBuffer,
                                       frameSize: frameSize)
        if ProcessInfo.processInfo.environment["PIANOCAM_DEBUG_CANDIDATES"] != nil {
            NSLog("PianoCam: candidate-count kind=%@ raw=%d frameSize=%dx%d",
                  kind == .black ? "black" : "white", raw.count,
                  Int(frameSize.width), Int(frameSize.height))
        }
        guard raw.count >= 7 else { return nil }

        let candidates = filterByCollinearity(raw)
        guard candidates.count >= 7 else { return nil }
        if ProcessInfo.processInfo.environment["PIANOCAM_ALIGNMENT_TRACE"] != nil,
           candidates.count != raw.count {
            NSLog("PianoCam: alignment-trace collinearity kind=%@ raw=%d kept=%d",
                  kind == .black ? "black" : "white", raw.count, candidates.count)
        }

        let ordered = orderedAlongKeyboardAxis(candidates)
        if ProcessInfo.processInfo.environment["PIANOCAM_DEBUG_CANDIDATES"] != nil {
            let summary = ordered.prefix(50).map {
                String(format: "(%.0f,%.0f %.0fx%.0f)",
                       $0.center.x, $0.center.y,
                       $0.bounds.width, $0.bounds.height)
            }.joined(separator: " ")
            NSLog("PianoCam: candidate-dump kind=%@ count=%d centers=%@",
                  kind == .black ? "black" : "white", ordered.count, summary)
        }
        guard let fit = bestFit(kind: kind,
                                orderedCandidates: ordered,
                                configuration: configuration,
                                frameSize: frameSize) else { return nil }

        let confidence = confidenceScore(kind: kind,
                                         candidateCount: fit.candidates.count,
                                         medianError: fit.medianError,
                                         frameSize: frameSize)
        return PianoKeyboardAlignment(configuration: configuration,
                                      homography: fit.homography,
                                      frameSize: frameSize,
                                      confidence: confidence,
                                      medianErrorPixels: fit.medianError,
                                      matchedKeyCount: fit.candidates.count)
    }

    private func detectCandidates(kind: KeyKind,
                                  pixelBuffer: CVPixelBuffer,
                                  frameSize: CGSize) throws -> [Candidate] {
        let request = VNDetectContoursRequest()
        // Vision applies contrast stretch before binarization; higher
        // values sharpen weak key-vs-background boundaries that the
        // default 1.0 (= no stretch) misses. 3.0 catches keys that
        // would otherwise merge with shadow in real photos.
        request.contrastAdjustment = 3.0
        request.detectsDarkOnLight = (kind == .black)
        request.maximumImageDimension = 960

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .up,
                                            options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first as? VNContoursObservation else { return [] }

        // Walk the full contour tree, not just the top level. Vision returns
        // a hierarchical tree where a contour's `childContours` are the
        // contours enclosed by it. When the keyboard sits on a dark
        // background (common for overhead photos), the outermost dark
        // contour is the entire backdrop and all 36 black keys end up as
        // grandchildren of it — invisible if we only walk roots. Each
        // candidate is filtered independently by area/aspect, so descending
        // costs only the contours that pass the cheap area check anyway.
        let frameArea = max(1, frameSize.width * frameSize.height)
        var candidates: [Candidate] = []
        var rejArea = 0, rejAspect = 0, rejCorners = 0
        var totalContours = 0
        var stack: [VNContour] = observation.topLevelContours
        let topLevelCount = stack.count
        while let contour = stack.popLast() {
            totalContours += 1
            stack.append(contentsOf: contour.childContours)

            let normalized = contour.normalizedPath.boundingBoxOfPath
            guard normalized.width > 0, normalized.height > 0 else { continue }

            let bounds = CGRect(x: normalized.minX * frameSize.width,
                                y: normalized.minY * frameSize.height,
                                width: normalized.width * frameSize.width,
                                height: normalized.height * frameSize.height)
            let area = bounds.width * bounds.height
            let areaFraction = area / frameArea
            // Keys are TALLER than wide in an overhead piano image
            // (assuming the keyboard is roughly horizontal in the frame —
            // the camera looking down at it). The old filter took
            // max(w/h, h/w), which let wide-and-short contours (wood
            // grain stripes in the cabinet above the keys, hand edges
            // below) pass as "candidates" too. That polluted the
            // candidate set with horizontal stripes scattered all over
            // the y axis. Constrain to height/width > 1.35 instead.
            let aspect = bounds.height / max(bounds.width, 1)

            if !(areaFraction > 0.00008 && areaFraction < 0.035) { rejArea += 1; continue }
            if !(aspect > 1.35 && aspect < 12) { rejAspect += 1; continue }

            let corners = Self.cornersFromContour(contour, frameSize: frameSize)
            if corners.count != 4 { rejCorners += 1; continue }
            candidates.append(Candidate(center: CGPoint(x: bounds.midX, y: bounds.midY),
                                        bounds: bounds,
                                        area: area,
                                        corners: corners))
        }

        if ProcessInfo.processInfo.environment["PIANOCAM_ALIGNMENT_TRACE"] != nil {
            NSLog("PianoCam: alignment-trace kind=%@ topLevel=%d total=%d accepted=%d rejArea=%d rejAspect=%d rejCorners=%d frame=%dx%d",
                  kind == .black ? "black" : "white",
                  topLevelCount, totalContours, candidates.count,
                  rejArea, rejAspect, rejCorners,
                  Int(frameSize.width), Int(frameSize.height))
        }
        return Array(candidates
            .sorted { $0.area > $1.area }
            .prefix(64))
    }

    private func orderedAlongKeyboardAxis(_ candidates: [Candidate]) -> [Candidate] {
        let (_, axis) = principalAxis(of: candidates)
        return candidates.sorted {
            projection($0.center, onto: axis) < projection($1.center, onto: axis)
        }
    }

    /// Compute (centroid, principalAxis) of a candidate set.
    /// The axis points roughly along the keyboard's left-to-right direction.
    private func principalAxis(of candidates: [Candidate]) -> (CGPoint, CGPoint) {
        let mean = candidates.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.center.x, y: $0.y + $1.center.y)
        }
        let count = CGFloat(max(1, candidates.count))
        let center = CGPoint(x: mean.x / count, y: mean.y / count)

        var xx: CGFloat = 0, xy: CGFloat = 0, yy: CGFloat = 0
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
        return (center, axis)
    }

    /// Drop candidates that lie too far off the keyboard's centerline.
    /// Real overhead piano photos have plenty of dark contours that pass
    /// the area/aspect filter but aren't keys — wood grain stripes above
    /// the keyboard, fingers or jacket edges below it. Real keys sit in a
    /// tight horizontal band along the keyboard's principal axis; spurious
    /// detections are scattered.
    ///
    /// Two-pass: first pass finds the axis using all candidates, second
    /// pass recomputes it using only the candidates within the band. This
    /// limits the influence of strong outliers on the band's orientation.
    private func filterByCollinearity(_ candidates: [Candidate]) -> [Candidate] {
        guard candidates.count >= 4 else { return candidates }

        func keep(against axis: CGPoint,
                  through center: CGPoint,
                  bandHalfHeight: CGFloat) -> [Candidate] {
            let perp = CGPoint(x: -axis.y, y: axis.x)
            return candidates.filter { c in
                let dx = c.center.x - center.x
                let dy = c.center.y - center.y
                let transverse = abs(dx * perp.x + dy * perp.y)
                return transverse <= bandHalfHeight
            }
        }

        // Adaptive band thickness: use the median transverse distance from
        // the centerline as the scale, then keep candidates within ~3× that.
        // For a real keyboard most candidates sit on the centerline with
        // small transverse distances; spurious detections (wood grain
        // above, hand edges below) are much farther. Using a robust
        // scale-from-data avoids hard-coding pixel thresholds that won't
        // generalize across image resolutions.
        func transverseDistances(of cands: [Candidate],
                                 axis: CGPoint,
                                 through center: CGPoint) -> [CGFloat] {
            let perp = CGPoint(x: -axis.y, y: axis.x)
            return cands.map { c in
                let dx = c.center.x - center.x
                let dy = c.center.y - center.y
                return abs(dx * perp.x + dy * perp.y)
            }
        }

        let (center0, axis0) = principalAxis(of: candidates)
        let dists0 = transverseDistances(of: candidates, axis: axis0, through: center0).sorted()
        let median0 = dists0[dists0.count / 2]
        // If the median distance is essentially zero (the spread axis is
        // very tight, e.g. a clean rendered image), use a small absolute
        // floor so a few stray detections don't drag the whole set out.
        let band0 = max(median0 * 3, 4)
        let firstPass = keep(against: axis0, through: center0, bandHalfHeight: band0)
        if firstPass.count < 7 { return candidates }

        let (center1, axis1) = principalAxis(of: firstPass)
        let dists1 = transverseDistances(of: firstPass, axis: axis1, through: center1).sorted()
        let median1 = dists1[dists1.count / 2]
        let band1 = max(median1 * 3, 4)
        let secondPass = keep(against: axis1, through: center1, bandHalfHeight: band1)
        return secondPass.count >= 7 ? secondPass : firstPass
    }

    private func bestFit(kind: KeyKind,
                         orderedCandidates: [Candidate],
                         configuration: PianoKeyboardConfiguration,
                         frameSize: CGSize) -> Fit? {
        // RANSAC-style robust fit. Real-world overhead photos miss keys —
        // hand occlusion, glare, low contrast on dark backdrops — so we
        // can't assume the detected candidates are N consecutive model
        // black keys. Instead, enumerate plausible (modelFirst, modelLast)
        // ranges that the candidates span in the model, hypothesize an
        // alignment via linear interpolation between those endpoints, then
        // count inliers (model keys whose projection lands near any
        // candidate). The hypothesis with the most inliers wins, then we
        // refit using just the inliers' corners for the final homography.
        let geometry = PianoKeyboardGeometry(configuration: configuration)
        let modelKeys = kind == .black ? geometry.blackKeys : geometry.whiteKeys
        let n = orderedCandidates.count
        let m = modelKeys.count
        guard m >= 7, n >= 7 else { return nil }

        // Cap the candidate set at the model size — extras are outliers we
        // tolerate as long as the inlier count is high. But linear-interp
        // hypothesis needs n <= m to be sensible; if n > m, slide a window.
        // Coarse threshold accepts ~1.5 key widths of slop in the initial
        // hypothesis (where linear interpolation between mFirst/mLast may
        // mis-assign some candidates because real black-key spacing is
        // non-uniform). After the refit on those inliers we tighten.
        let frameMinDim = min(frameSize.width, frameSize.height)
        let coarseThreshold = CGFloat(0.08) * frameMinDim
        let fineThreshold = CGFloat(0.025) * frameMinDim
        let candidateWindows: [[Candidate]] = {
            if n <= m { return [orderedCandidates] }
            var windows: [[Candidate]] = []
            for start in 0...(n - m) {
                windows.append(Array(orderedCandidates[start..<(start + m)]))
            }
            return windows
        }()

        // Normalize each candidate's position to 0..1 along the keyboard
        // axis using projection onto the principal axis of the candidate
        // set. Reusing the ordering axis derived in orderedAlongKeyboardAxis.
        func normalizedPositions(_ candidates: [Candidate]) -> [CGFloat]? {
            let mean = candidates.reduce(CGPoint.zero) {
                CGPoint(x: $0.x + $1.center.x, y: $0.y + $1.center.y)
            }
            let cnt = CGFloat(candidates.count)
            let center = CGPoint(x: mean.x / cnt, y: mean.y / cnt)
            var xx: CGFloat = 0, xy: CGFloat = 0, yy: CGFloat = 0
            for c in candidates {
                let dx = c.center.x - center.x
                let dy = c.center.y - center.y
                xx += dx * dx; xy += dx * dy; yy += dy * dy
            }
            let angle = 0.5 * atan2(2 * xy, xx - yy)
            var axis = CGPoint(x: cos(angle), y: sin(angle))
            if abs(axis.x) < 0.2 { axis = CGPoint(x: -axis.y, y: axis.x) }
            if axis.x < 0 { axis = CGPoint(x: -axis.x, y: -axis.y) }
            let projs = candidates.map { $0.center.x * axis.x + $0.center.y * axis.y }
            guard let lo = projs.min(), let hi = projs.max(), hi > lo else { return nil }
            return projs.map { ($0 - lo) / (hi - lo) }
        }

        var best: Fit?
        var rangesTried = 0, degenerateSkipped = 0, fitFailed = 0
        var hypotheses = 0, coarseEnough = 0, fineEnough = 0, bestCoarseInliers = 0

        for window in candidateWindows {
            let k = window.count
            guard let pos = normalizedPositions(window) else { continue }

            for mFirst in 0...(m - k) {
                for mLast in (mFirst + k - 1)..<m {
                    rangesTried += 1
                    // Build hypothesis: linearly interpolate each candidate's
                    // position to a model index. We don't dedupe — real
                    // candidates may cluster (multiple candidates mapping
                    // to the same model index produces redundant
                    // constraints, which the least-squares fit handles).
                    // The inlier refinement step recovers the real
                    // correspondence regardless.
                    var modelIndices = [Int](repeating: 0, count: k)
                    for i in 0..<k {
                        let mi = Int((CGFloat(mFirst) + pos[i] * CGFloat(mLast - mFirst)).rounded())
                        modelIndices[i] = max(mFirst, min(mLast, mi))
                    }

                    var observed: [CGPoint] = []
                    var model: [CGPoint] = []
                    observed.reserveCapacity(k * 4)
                    model.reserveCapacity(k * 4)
                    for (i, mi) in modelIndices.enumerated() {
                        observed.append(contentsOf: window[i].corners)
                        model.append(contentsOf: modelKeys[mi].modelPolygon)
                    }
                    guard let h0 = PianoHomography.fitAffine(modelPoints: model, imagePoints: observed) else {
                        fitFailed += 1
                        continue
                    }

                    // Inlier search: each model key picks its nearest
                    // candidate. We allow multiple model keys to share the
                    // same candidate — in practice that gives a richer
                    // (over-determined) least-squares refit. The
                    // refit-and-confirm pass below drops any inliers that
                    // the refitted homography pushes past threshold, which
                    // is what eliminates the wild post-refit outliers.
                    func inliers(under threshold: CGFloat,
                                 using homography: PianoHomography)
                        -> [(PianoKeyGeometry, Candidate)] {
                        var result: [(PianoKeyGeometry, Candidate)] = []
                        for modelKey in modelKeys {
                            let projected = homography.project(modelKey.modelCenter)
                            var bestDist: CGFloat = .infinity
                            var bestCand: Candidate? = nil
                            for cand in orderedCandidates {
                                let d = hypot(cand.center.x - projected.x,
                                              cand.center.y - projected.y)
                                if d < bestDist { bestDist = d; bestCand = cand }
                            }
                            if let bc = bestCand, bestDist <= threshold {
                                result.append((modelKey, bc))
                            }
                        }
                        return result
                    }

                    hypotheses += 1
                    let coarse = inliers(under: coarseThreshold, using: h0)
                    bestCoarseInliers = max(bestCoarseInliers, coarse.count)
                    guard coarse.count >= 7 else { continue }
                    coarseEnough += 1

                    // Refit on coarse inliers
                    var refObs: [CGPoint] = []
                    var refMdl: [CGPoint] = []
                    refObs.reserveCapacity(coarse.count * 4)
                    refMdl.reserveCapacity(coarse.count * 4)
                    for (modelKey, cand) in coarse {
                        refObs.append(contentsOf: cand.corners)
                        refMdl.append(contentsOf: modelKey.modelPolygon)
                    }
                    guard let hMid = PianoHomography.fitAffine(modelPoints: refMdl, imagePoints: refObs) else {
                        continue
                    }

                    // Tighten: take inliers under the fine threshold of the
                    // refit homography, and refit one more time.
                    let fine = inliers(under: fineThreshold, using: hMid)
                    guard fine.count >= 7 else { continue }
                    fineEnough += 1

                    refObs.removeAll(keepingCapacity: true)
                    refMdl.removeAll(keepingCapacity: true)
                    for (modelKey, cand) in fine {
                        refObs.append(contentsOf: cand.corners)
                        refMdl.append(contentsOf: modelKey.modelPolygon)
                    }
                    guard let hFinal = PianoHomography.fitAffine(modelPoints: refMdl, imagePoints: refObs) else {
                        continue
                    }

                    // Confirm inliers against the refit homography. The
                    // refit can move the fit by several keys' worth, so
                    // some "fine" inliers picked against hMid may now lie
                    // far from any model projection under hFinal. Drop
                    // those before scoring; if too few survive, fall back
                    // to the pre-confirm set so we don't regress on frames
                    // where the refit is sensible but tightens the fit
                    // enough to clip otherwise-valid points.
                    var confirmed: [(PianoKeyGeometry, Candidate, CGFloat)] = []
                    for (modelKey, cand) in fine {
                        let p = hFinal.project(modelKey.modelCenter)
                        let d = hypot(cand.center.x - p.x, cand.center.y - p.y)
                        if d <= fineThreshold {
                            confirmed.append((modelKey, cand, d))
                        }
                    }
                    if confirmed.count < 7 {
                        // Fallback: keep fine inliers but recompute their
                        // distances against hFinal so the score reflects
                        // the actual fit, not the stale hMid values.
                        for (modelKey, cand) in fine {
                            let p = hFinal.project(modelKey.modelCenter)
                            let d = hypot(cand.center.x - p.x, cand.center.y - p.y)
                            confirmed.append((modelKey, cand, d))
                        }
                    }

                    // Sanity-check the homography by walking the projected
                    // model-key centers in order. For a real keyboard
                    // these form a roughly straight left-to-right line;
                    // a fit that satisfies a few tight inliers but is
                    // globally wrong tends to fold the line back on
                    // itself or project some keys to infinity. Reject if
                    // consecutive steps disagree on direction (the dot
                    // product with the mean step goes negative) or any
                    // projection is non-finite.
                    var centers: [CGPoint] = []
                    centers.reserveCapacity(modelKeys.count)
                    var sane = true
                    for mk in modelKeys {
                        let p = hFinal.project(mk.modelCenter)
                        if !p.x.isFinite || !p.y.isFinite { sane = false; break }
                        // Also project the polygon corners — the path
                        // overlay uses those, and a center can be finite
                        // while a corner falls into the abs(w) < epsilon
                        // singularity (different model y, different
                        // projective denominator). If any corner blows up,
                        // the rendered overlay will silently fail to draw.
                        for corner in mk.modelPolygon {
                            let cp = hFinal.project(corner)
                            if !cp.x.isFinite || !cp.y.isFinite {
                                sane = false
                                break
                            }
                        }
                        if !sane { break }
                        centers.append(p)
                    }
                    if !sane { continue }
                    var steps: [CGPoint] = []
                    steps.reserveCapacity(centers.count - 1)
                    for i in 1..<centers.count {
                        steps.append(CGPoint(x: centers[i].x - centers[i - 1].x,
                                             y: centers[i].y - centers[i - 1].y))
                    }
                    let stepCount = CGFloat(steps.count)
                    let meanDx = steps.reduce(0) { $0 + $1.x } / stepCount
                    let meanDy = steps.reduce(0) { $0 + $1.y } / stepCount
                    var monotonic = true
                    for s in steps {
                        if s.x * meanDx + s.y * meanDy <= 0 { monotonic = false; break }
                    }
                    if !monotonic { continue }

                    // The projected keyboard must span a meaningful
                    // fraction of the candidate-x range. We've seen
                    // fits that collapse all 88 keys into a 1-pixel-wide
                    // x column (monotonic in y only, satisfying a few
                    // inliers stacked vertically). Require the projected
                    // x-span to be at least a fraction of the input
                    // candidate-x-span so global collapse is rejected.
                    let cxs = orderedCandidates.map { $0.center.x }
                    let candXSpan = (cxs.max() ?? 0) - (cxs.min() ?? 0)
                    let pxs = centers.map(\.x)
                    let projXSpan = (pxs.max() ?? 0) - (pxs.min() ?? 0)
                    if ProcessInfo.processInfo.environment["PIANOCAM_ALIGNMENT_TRACE_DETAIL"] != nil
                        && confirmed.count >= 10 {
                        NSLog("PianoCam: alignment-trace xspan kind=%@ mFirst=%d mLast=%d projXSpan=%.0f candXSpan=%.0f inliers=%d",
                              kind == .black ? "black" : "white",
                              mFirst, mLast, Double(projXSpan), Double(candXSpan), confirmed.count)
                    }
                    if projXSpan < max(candXSpan * 0.5, 50) { continue }

                    // The projected key height should be in the same
                    // ballpark as the real candidates' bounding-box
                    // height. We've seen hypotheses with 10 tightly-fit
                    // inliers blow the y-scale up to ~6× the true key
                    // height — keys then render as thin lines extending
                    // far above and below the band. Compare the
                    // projected polygon's front-to-back distance for one
                    // model key against the median candidate height
                    // (which tracks actual key size).
                    let firstKey = modelKeys.first!
                    let topProj = hFinal.project(firstKey.modelPolygon[0])
                    let botProj = hFinal.project(firstKey.modelPolygon[3])
                    let projKeyHeight = hypot(topProj.x - botProj.x,
                                              topProj.y - botProj.y)
                    let candHeights = orderedCandidates.map { $0.bounds.height }.sorted()
                    let medianCandHeight = candHeights[candHeights.count / 2]
                    // Candidates are usually as tall as a key (black key
                    // or white key, whichever was detected). Allow a 2×
                    // margin in each direction to absorb perspective.
                    let scaleRatio = projKeyHeight / max(medianCandHeight, 1)
                    // The bbox height of a contour can be much smaller
                    // than the true key height (when the contour only
                    // captures a portion — e.g. a white-key contour
                    // gives the part not covered by black keys). Give
                    // the upper end of the range generous slack; the
                    // catastrophic degenerate cases push ratio above 7×.
                    if scaleRatio < 0.3 || scaleRatio > 6.0 { continue }

                    var errors: [CGFloat] = confirmed.map { $0.2 }
                    errors.sort()
                    let median = errors[errors.count / 2]

                    if ProcessInfo.processInfo.environment["PIANOCAM_ALIGNMENT_TRACE_DETAIL"] != nil
                        && (best == nil || fine.count > (best?.candidates.count ?? 0)) {
                        let summary = errors.map { String(format: "%.0f", Double($0)) }.joined(separator: ",")
                        NSLog("PianoCam: alignment-trace fit-detail kind=%@ mFirst=%d mLast=%d inliers=%d errors=[%@]",
                              kind == .black ? "black" : "white",
                              mFirst, mLast, fine.count, summary)
                    }
                    let fit = Fit(homography: hFinal,
                                  medianError: median,
                                  candidates: confirmed.map { $0.1 })
                    // Rank by the same confidence formula the final
                    // output uses, so a tight 12-inlier fit (e.g. 14 px
                    // error) beats a loose 20-inlier one (e.g. 114 px).
                    // Count alone would let the loose fit win on inlier
                    // count, which is the wrong answer for actually
                    // rendering aligned key highlights.
                    func score(of f: Fit) -> Double {
                        let countScore = min(1.0, Double(f.candidates.count)
                                             / (kind == .black ? 18.0 : 26.0))
                        let frameScale = Double(max(frameSize.width, frameSize.height))
                        let errorScore = max(0.0,
                            1.0 - Double(f.medianError) / frameScale / 0.018)
                        return countScore * 0.45 + errorScore * 0.55
                    }
                    if best.map({ score(of: fit) > score(of: $0) }) ?? true {
                        best = fit
                        if ProcessInfo.processInfo.environment["PIANOCAM_ALIGNMENT_TRACE_DETAIL"] != nil {
                            // Project a model key's two y-extremes to
                            // measure the homography's effective y-scale
                            // on this hypothesis. A tiny value here means
                            // keys will be rendered as thin lines.
                            let firstKey = modelKeys.first!
                            let topPt = firstKey.modelPolygon[0]
                            let botPt = firstKey.modelPolygon[3]
                            let topProj = hFinal.project(topPt)
                            let botProj = hFinal.project(botPt)
                            let keyHeightPx = hypot(topProj.x - botProj.x,
                                                    topProj.y - botProj.y)
                            NSLog("PianoCam: alignment-trace winning kind=%@ mFirst=%d mLast=%d inliers=%d median=%.1f keyHeightPx=%.1f h20=%.6f h21=%.6f",
                                  kind == .black ? "black" : "white",
                                  mFirst, mLast, confirmed.count, Double(median),
                                  Double(keyHeightPx),
                                  Double(hFinal.h20), Double(hFinal.h21))
                        }
                    }
                }
            }
        }

        if ProcessInfo.processInfo.environment["PIANOCAM_ALIGNMENT_TRACE"] != nil {
            NSLog("PianoCam: alignment-trace bestFit kind=%@ n=%d m=%d ranges=%d degenerate=%d fitFailed=%d hypotheses=%d coarse>=7=%d fine>=7=%d bestCoarseInliers=%d coarseThresh=%.0fpx",
                  kind == .black ? "black" : "white",
                  n, m, rangesTried, degenerateSkipped, fitFailed, hypotheses,
                  coarseEnough, fineEnough, bestCoarseInliers,
                  Double(coarseThreshold))
        }
        return best
    }

    private func confidenceScore(kind: KeyKind,
                                 candidateCount: Int,
                                 medianError: CGFloat,
                                 frameSize: CGSize) -> Double {
        // "Good" candidate count is ~50% of the relevant model: 18 of 36
        // black keys, 26 of 52 white keys.
        let countScore = min(1, Double(candidateCount) / (kind == .black ? 18.0 : 26.0))
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
    /// flipped relative to display.
    ///
    /// Returned ordering: [BL, BR, TR, TL] in display terms, matching
    /// PianoKeyGeometry.modelPolygon — which is [(x, 0), (x+1, 0),
    /// (x+1, 1), (x, 1)] with model y=0 meaning the *front* of the
    /// keyboard (player side, bottom of an overhead display) and y=1
    /// the back. Earlier we returned CW [TL, TR, BR, BL]; that opposed
    /// the model's CCW orientation, so the homography fitter learned a
    /// reflection that visibly mirrored the overlay top↔bottom.
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
        // Note: pts[idx].y is bottom-origin (Vision). To convert to a
        // standard top-origin display coordinate we'd compute (1 - y) * h.
        // But the candidates we feed into the homography fit are also in
        // bottom-origin (the same `bounds` y = normalized.minY * h), and
        // the model polygon uses model-y=0 for *front* (which is bottom
        // of display = bottom-origin small y). The two conventions
        // line up as long as we don't flip — keep raw y * h and let the
        // affine fit absorb the sign.
        func scale(_ idx: Int) -> CGPoint {
            CGPoint(x: CGFloat(pts[idx].x) * w, y: CGFloat(pts[idx].y) * h)
        }
        return [scale(blIdx), scale(brIdx), scale(trIdx), scale(tlIdx)]
    }
}
