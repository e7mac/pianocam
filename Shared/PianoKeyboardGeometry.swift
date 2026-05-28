//
//  PianoKeyboardGeometry.swift
//  PianoCam
//
//  Parametric piano-key geometry and homography fitting used by the
//  overhead-camera alignment path.
//

import CoreGraphics
import Foundation

struct PianoKeyboardConfiguration: Equatable {
    var keyCount: Int
    var lowestMIDINote: Int

    static let fullSize = PianoKeyboardConfiguration(keyCount: 88, lowestMIDINote: 21)

    var highestMIDINote: Int { lowestMIDINote + keyCount - 1 }
}

struct PianoKeyGeometry {
    let noteNumber: Int
    let isBlack: Bool
    let modelPolygon: [CGPoint]
    let modelCenter: CGPoint
}

struct PianoKeyboardGeometry {
    let configuration: PianoKeyboardConfiguration
    let keys: [PianoKeyGeometry]
    let whiteKeyCount: Int

    init(configuration: PianoKeyboardConfiguration) {
        self.configuration = configuration

        var keys: [PianoKeyGeometry] = []
        var whiteIndexByNote: [Int: Int] = [:]
        var whiteIndex = 0

        for note in configuration.lowestMIDINote...configuration.highestMIDINote {
            if Self.isWhite(note) {
                whiteIndexByNote[note] = whiteIndex
                let x = CGFloat(whiteIndex)
                let poly = [
                    CGPoint(x: x, y: 0),
                    CGPoint(x: x + 1, y: 0),
                    CGPoint(x: x + 1, y: 1),
                    CGPoint(x: x, y: 1)
                ]
                keys.append(PianoKeyGeometry(noteNumber: note,
                                             isBlack: false,
                                             modelPolygon: poly,
                                             modelCenter: CGPoint(x: x + 0.5, y: 0.46)))
                whiteIndex += 1
            }
        }

        for note in configuration.lowestMIDINote...configuration.highestMIDINote where !Self.isWhite(note) {
            guard let previousWhite = Self.previousWhiteNote(before: note),
                  let wi = whiteIndexByNote[previousWhite] else { continue }
            let blackWidth: CGFloat = 0.58
            let blackFrontY: CGFloat = 0.39
            let centerX = CGFloat(wi) + Self.blackOffsetFromPreviousWhite(for: note)
            let x0 = centerX - blackWidth / 2
            let x1 = centerX + blackWidth / 2
            let poly = [
                CGPoint(x: x0, y: blackFrontY),
                CGPoint(x: x1, y: blackFrontY),
                CGPoint(x: x1, y: 1),
                CGPoint(x: x0, y: 1)
            ]
            keys.append(PianoKeyGeometry(noteNumber: note,
                                         isBlack: true,
                                         modelPolygon: poly,
                                         modelCenter: CGPoint(x: centerX, y: (blackFrontY + 1) / 2)))
        }

        self.keys = keys.sorted {
            if $0.noteNumber == $1.noteNumber { return !$0.isBlack && $1.isBlack }
            return $0.noteNumber < $1.noteNumber
        }
        self.whiteKeyCount = whiteIndex
    }

    var blackKeys: [PianoKeyGeometry] {
        keys.filter(\.isBlack)
    }

    var whiteKeys: [PianoKeyGeometry] {
        keys.filter { !$0.isBlack }
    }

    func key(for noteNumber: Int) -> PianoKeyGeometry? {
        keys.first { $0.noteNumber == noteNumber }
    }

    static func isWhite(_ noteNumber: Int) -> Bool {
        [0, 2, 4, 5, 7, 9, 11].contains(noteNumber % 12)
    }

    private static func previousWhiteNote(before note: Int) -> Int? {
        var n = note - 1
        while n >= 0 {
            if isWhite(n) { return n }
            n -= 1
        }
        return nil
    }

    /// Black keys are not centered uniformly between adjacent white fronts.
    /// These fractions are measured from the left edge of the previous white
    /// key in white-key-width units and intentionally differ per pitch class.
    static func blackOffsetFromPreviousWhite(for noteNumber: Int) -> CGFloat {
        switch noteNumber % 12 {
        case 1: return 0.62  // C#
        case 3: return 0.68  // D#
        case 6: return 0.58  // F#
        case 8: return 0.64  // G#
        case 10: return 0.70 // A#
        default: return 0.5
        }
    }
}

/// 3x3 matrix used during Hartley normalization. We only need
/// multiply and inverse; this is much simpler than pulling in simd.
private struct Matrix3x3 {
    let h00, h01, h02: CGFloat
    let h10, h11, h12: CGFloat
    let h20, h21, h22: CGFloat

    func multiply(_ b: Matrix3x3) -> Matrix3x3 {
        Matrix3x3(
            h00: h00 * b.h00 + h01 * b.h10 + h02 * b.h20,
            h01: h00 * b.h01 + h01 * b.h11 + h02 * b.h21,
            h02: h00 * b.h02 + h01 * b.h12 + h02 * b.h22,
            h10: h10 * b.h00 + h11 * b.h10 + h12 * b.h20,
            h11: h10 * b.h01 + h11 * b.h11 + h12 * b.h21,
            h12: h10 * b.h02 + h11 * b.h12 + h12 * b.h22,
            h20: h20 * b.h00 + h21 * b.h10 + h22 * b.h20,
            h21: h20 * b.h01 + h21 * b.h11 + h22 * b.h21,
            h22: h20 * b.h02 + h21 * b.h12 + h22 * b.h22)
    }

    func inverse() -> Matrix3x3 {
        let c00 = h11 * h22 - h12 * h21
        let c01 = h12 * h20 - h10 * h22
        let c02 = h10 * h21 - h11 * h20
        let det = h00 * c00 + h01 * c01 + h02 * c02
        let invDet = 1.0 / det
        return Matrix3x3(
            h00: c00 * invDet,
            h01: (h02 * h21 - h01 * h22) * invDet,
            h02: (h01 * h12 - h02 * h11) * invDet,
            h10: c01 * invDet,
            h11: (h00 * h22 - h02 * h20) * invDet,
            h12: (h02 * h10 - h00 * h12) * invDet,
            h20: c02 * invDet,
            h21: (h01 * h20 - h00 * h21) * invDet,
            h22: (h00 * h11 - h01 * h10) * invDet)
    }
}

struct PianoHomography {
    let h00: CGFloat
    let h01: CGFloat
    let h02: CGFloat
    let h10: CGFloat
    let h11: CGFloat
    let h12: CGFloat
    let h20: CGFloat
    let h21: CGFloat

    func project(_ point: CGPoint) -> CGPoint {
        let x = point.x
        let y = point.y
        let w = h20 * x + h21 * y + 1
        // Near-zero denominator means a near-degenerate homography (points
        // map to or through infinity). Return non-finite coordinates so
        // callers can detect and reject — the previous .zero fallback hid
        // degenerate projections inside an in-band-looking (0, 0).
        guard abs(w) > 0.000001 else {
            return CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        }
        return CGPoint(x: (h00 * x + h01 * y + h02) / w,
                       y: (h10 * x + h11 * y + h12) / w)
    }

    func projectPolygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: project(first))
        for point in points.dropFirst() {
            path.addLine(to: project(point))
        }
        path.closeSubpath()
        return path
    }

    /// Fit a 6-parameter affine transform (no perspective). For overhead
    /// piano photos where the keyboard is far enough from the camera that
    /// perspective foreshortening is small, this is more stable than the
    /// 8-parameter homography: near-collinear source points (the keyboard
    /// is mostly a horizontal line) don't constrain the two perspective
    /// parameters, so the full homography fit collapses into a degenerate
    /// solution. Affine sidesteps that entirely.
    static func fitAffine(modelPoints: [CGPoint], imagePoints: [CGPoint]) -> PianoHomography? {
        guard modelPoints.count == imagePoints.count, modelPoints.count >= 3 else { return nil }
        // 6 unknowns (a, b, tx, c, d, ty) split into two independent 3x3
        // LSQR systems: one for x (u = aX + bY + tx), one for y.
        var atax = Array(repeating: Array(repeating: CGFloat(0), count: 3), count: 3)
        var atbx = Array(repeating: CGFloat(0), count: 3)
        var atay = Array(repeating: Array(repeating: CGFloat(0), count: 3), count: 3)
        var atby = Array(repeating: CGFloat(0), count: 3)
        for (model, image) in zip(modelPoints, imagePoints) {
            let row: [CGFloat] = [model.x, model.y, 1]
            for i in 0..<3 {
                atbx[i] += row[i] * image.x
                atby[i] += row[i] * image.y
                for j in 0..<3 {
                    atax[i][j] += row[i] * row[j]
                    atay[i][j] += row[i] * row[j]
                }
            }
        }
        guard let xParams = solve(atax, atbx),
              let yParams = solve(atay, atby) else { return nil }
        return PianoHomography(h00: xParams[0], h01: xParams[1], h02: xParams[2],
                               h10: yParams[0], h11: yParams[1], h12: yParams[2],
                               h20: 0, h21: 0)
    }

    static func fit(modelPoints: [CGPoint], imagePoints: [CGPoint]) -> PianoHomography? {
        guard modelPoints.count == imagePoints.count, modelPoints.count >= 4 else { return nil }

        // Hartley normalization: shift each point set so its centroid is at
        // the origin and its average distance from origin is sqrt(2). This
        // equalizes the magnitudes that the LSQR sees — without it, model
        // coords (0..52) and image coords (0..2000+) produce matrix entries
        // varying by 40× and the perspective parameters become wildly
        // ill-conditioned for near-horizontal point sets (the classic
        // "homography from coplanar points on a line" failure mode that
        // collapses the keyboard into a single column).
        guard let (normalizedModel, modelDenorm) = hartleyNormalize(modelPoints),
              let (normalizedImage, imageNorm) = hartleyNormalize(imagePoints)
        else { return nil }

        var ata = Array(repeating: Array(repeating: CGFloat(0), count: 8), count: 8)
        var atb = Array(repeating: CGFloat(0), count: 8)

        for (model, image) in zip(normalizedModel, normalizedImage) {
            let x = model.x
            let y = model.y
            let u = image.x
            let v = image.y
            accumulate(row: [x, y, 1, 0, 0, 0, -u * x, -u * y], rhs: u, ata: &ata, atb: &atb)
            accumulate(row: [0, 0, 0, x, y, 1, -v * x, -v * y], rhs: v, ata: &ata, atb: &atb)
        }

        guard let h = solve(ata, atb) else { return nil }
        let normalized = Matrix3x3(h00: h[0], h01: h[1], h02: h[2],
                                   h10: h[3], h11: h[4], h12: h[5],
                                   h20: h[6], h21: h[7], h22: 1)
        // Denormalize: H = T_image^-1 * H_normalized * T_model
        let denormalized = imageNorm.inverse().multiply(normalized).multiply(modelDenorm)
        let scale = denormalized.h22 != 0 ? denormalized.h22 : 1
        return PianoHomography(h00: denormalized.h00 / scale,
                               h01: denormalized.h01 / scale,
                               h02: denormalized.h02 / scale,
                               h10: denormalized.h10 / scale,
                               h11: denormalized.h11 / scale,
                               h12: denormalized.h12 / scale,
                               h20: denormalized.h20 / scale,
                               h21: denormalized.h21 / scale)
    }

    /// Returns (points-after-T, T) where T is the similarity transform that
    /// shifts the centroid to origin and rescales so the average distance
    /// from origin is sqrt(2). Returns nil if all points coincide.
    private static func hartleyNormalize(_ points: [CGPoint])
        -> ([CGPoint], Matrix3x3)? {
        let count = CGFloat(points.count)
        let cx = points.reduce(0) { $0 + $1.x } / count
        let cy = points.reduce(0) { $0 + $1.y } / count
        let meanDist = points.reduce(0) {
            $0 + hypot($1.x - cx, $1.y - cy)
        } / count
        guard meanDist > 0.000001 else { return nil }
        let s = CGFloat(sqrt(2.0)) / meanDist
        let transformed = points.map { CGPoint(x: ($0.x - cx) * s,
                                               y: ($0.y - cy) * s) }
        let T = Matrix3x3(h00: s,  h01: 0, h02: -s * cx,
                          h10: 0,  h11: s, h12: -s * cy,
                          h20: 0,  h21: 0, h22: 1)
        return (transformed, T)
    }

    private static func accumulate(row: [CGFloat],
                                   rhs: CGFloat,
                                   ata: inout [[CGFloat]],
                                   atb: inout [CGFloat]) {
        for i in 0..<8 {
            atb[i] += row[i] * rhs
            for j in 0..<8 {
                ata[i][j] += row[i] * row[j]
            }
        }
    }

    private static func solve(_ a: [[CGFloat]], _ b: [CGFloat]) -> [CGFloat]? {
        var m = a
        var rhs = b
        let n = rhs.count

        for col in 0..<n {
            var pivot = col
            var pivotAbs = abs(m[col][col])
            for row in (col + 1)..<n {
                let value = abs(m[row][col])
                if value > pivotAbs {
                    pivot = row
                    pivotAbs = value
                }
            }
            guard pivotAbs > 0.0000001 else { return nil }
            if pivot != col {
                m.swapAt(pivot, col)
                rhs.swapAt(pivot, col)
            }

            let divisor = m[col][col]
            for j in col..<n { m[col][j] /= divisor }
            rhs[col] /= divisor

            for row in 0..<n where row != col {
                let factor = m[row][col]
                guard factor != 0 else { continue }
                for j in col..<n {
                    m[row][j] -= factor * m[col][j]
                }
                rhs[row] -= factor * rhs[col]
            }
        }
        return rhs
    }
}

struct PianoKeyboardAlignment {
    let configuration: PianoKeyboardConfiguration
    let homography: PianoHomography
    let frameSize: CGSize
    let confidence: Double
    let medianErrorPixels: CGFloat
    let matchedKeyCount: Int
    let createdAt: Date

    private let pathsByMIDINote: [Int: CGPath]

    init(configuration: PianoKeyboardConfiguration,
         homography: PianoHomography,
         frameSize: CGSize,
         confidence: Double,
         medianErrorPixels: CGFloat,
         matchedKeyCount: Int,
         createdAt: Date = Date()) {
        self.configuration = configuration
        self.homography = homography
        self.frameSize = frameSize
        self.confidence = confidence
        self.medianErrorPixels = medianErrorPixels
        self.matchedKeyCount = matchedKeyCount
        self.createdAt = createdAt

        let geometry = PianoKeyboardGeometry(configuration: configuration)
        var paths: [Int: CGPath] = [:]
        for key in geometry.keys {
            paths[key.noteNumber] = homography.projectPolygon(key.modelPolygon)
        }
        self.pathsByMIDINote = paths
    }

    func screenPolygonForMIDINote(noteNumber: Int) -> CGPath? {
        pathsByMIDINote[noteNumber]
    }
}
