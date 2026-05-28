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
        guard abs(w) > 0.000001 else { return .zero }
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

    static func fit(modelPoints: [CGPoint], imagePoints: [CGPoint]) -> PianoHomography? {
        guard modelPoints.count == imagePoints.count, modelPoints.count >= 4 else { return nil }

        var ata = Array(repeating: Array(repeating: CGFloat(0), count: 8), count: 8)
        var atb = Array(repeating: CGFloat(0), count: 8)

        for (model, image) in zip(modelPoints, imagePoints) {
            let x = model.x
            let y = model.y
            let u = image.x
            let v = image.y
            accumulate(row: [x, y, 1, 0, 0, 0, -u * x, -u * y], rhs: u, ata: &ata, atb: &atb)
            accumulate(row: [0, 0, 0, x, y, 1, -v * x, -v * y], rhs: v, ata: &ata, atb: &atb)
        }

        guard let h = solve(ata, atb) else { return nil }
        return PianoHomography(h00: h[0], h01: h[1], h02: h[2],
                               h10: h[3], h11: h[4], h12: h[5],
                               h20: h[6], h21: h[7])
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
