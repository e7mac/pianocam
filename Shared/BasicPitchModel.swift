//
//  BasicPitchModel.swift
//  PianoCam
//
//  Native CoreML wrapper around Spotify's Basic Pitch model. Owns:
//   - model loading (compiles .mlpackage if needed)
//   - output naming (probes which output is note vs onset on first call)
//   - one-shot inference: 2-second mono window of float samples →
//     (note: [Float], onset: [Float]), each sized 172 frames × 88 pitches.
//
//  Used by both the live `BasicPitchInference` (streaming inference) and
//  the offline `OfflineBasicPitchAnalyzer` (batch over a long buffer).
//

import CoreML
import Foundation

final class BasicPitchModel {
    /// Audio sample-rate the model expects.
    static let sampleRate: Double = 22_050
    /// Samples per inference window (2 seconds).
    static let windowSamples = 43_844
    /// Output frames per window.
    static let frameCount = 172
    /// Pitches per frame (MIDI 21–108).
    static let pitchCount = 88
    /// Seconds per frame in the model output.
    static let frameDuration: Double = 2.0 / Double(frameCount)

    private let model: MLModel
    private let inputName: String
    private let outputNames: [String]
    private var noteOutputName: String?
    private var onsetOutputName: String?

    init() throws {
        // At runtime, Xcode ships a compiled `.mlmodelc`. Fall back to the
        // raw `.mlpackage` for projects that haven't yet rebuilt.
        guard let url = Bundle.main.url(forResource: "BasicPitch", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "BasicPitch", withExtension: "mlpackage") else {
            throw NSError(domain: "PianoCam", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "BasicPitch model not in app bundle"
            ])
        }
        let compiledURL: URL = (url.pathExtension == "mlmodelc")
            ? url
            : try MLModel.compileModel(at: url)

        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        self.model = try MLModel(contentsOf: compiledURL, configuration: cfg)

        let desc = self.model.modelDescription
        guard let inName = desc.inputDescriptionsByName.keys.first else {
            throw NSError(domain: "PianoCam", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "BasicPitch model has no input"
            ])
        }
        self.inputName = inName
        self.outputNames = Array(desc.outputDescriptionsByName.keys).sorted()
        NSLog("BasicPitchModel: CoreML loaded — input=\(inName) outputs=\(outputNames)")
    }

    /// Run one window through the model. `audio` must be exactly
    /// `windowSamples` floats. Returns row-major arrays sized
    /// `frameCount * pitchCount`. The first call probes which output is the
    /// note map vs the onset map (note has higher mean — sustained; onset is
    /// sparse).
    func infer(audio: [Float]) throws -> (note: [Float], onset: [Float]) {
        precondition(audio.count == Self.windowSamples,
                     "BasicPitchModel.infer expected \(Self.windowSamples) samples, got \(audio.count)")

        let arr = try MLMultiArray(
            shape: [1, NSNumber(value: Self.windowSamples), 1],
            dataType: .float32
        )
        let dst = arr.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSamples)
        audio.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: Self.windowSamples)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: arr])
        let out = try model.prediction(from: provider)

        // Filter outputs to the (1, 172, 88)-shaped ones: note + onset.
        var pitchOutputs: [(name: String, arr: MLMultiArray)] = []
        for name in outputNames {
            guard let v = out.featureValue(for: name)?.multiArrayValue else { continue }
            if v.shape.count == 3, v.shape[2].intValue == Self.pitchCount {
                pitchOutputs.append((name, v))
            }
        }
        guard pitchOutputs.count >= 2 else {
            throw NSError(domain: "PianoCam", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "BasicPitch produced \(pitchOutputs.count) pitch outputs"
            ])
        }

        if noteOutputName == nil || onsetOutputName == nil {
            let m0 = Self.mean(of: pitchOutputs[0].arr)
            let m1 = Self.mean(of: pitchOutputs[1].arr)
            if m0 >= m1 {
                noteOutputName = pitchOutputs[0].name
                onsetOutputName = pitchOutputs[1].name
            } else {
                noteOutputName = pitchOutputs[1].name
                onsetOutputName = pitchOutputs[0].name
            }
            NSLog("BasicPitchModel: probed — note=\(noteOutputName!) (mean=\(String(format: "%.3f", max(m0, m1)))), onset=\(onsetOutputName!) (mean=\(String(format: "%.3f", min(m0, m1)))) strides=\(pitchOutputs[0].arr.strides)")
        }

        guard let nName = noteOutputName, let oName = onsetOutputName,
              let noteArr = out.featureValue(for: nName)?.multiArrayValue,
              let onsetArr = out.featureValue(for: oName)?.multiArrayValue else {
            throw NSError(domain: "PianoCam", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "BasicPitch output not bindable"
            ])
        }

        return (Self.flatten(noteArr), Self.flatten(onsetArr))
    }

    // MARK: - Helpers

    /// Pull the (frame, pitch) values into a row-major `[frame*88 + pitch]`
    /// array regardless of CoreML's stride layout.
    private static func flatten(_ arr: MLMultiArray) -> [Float] {
        let frames = Self.frameCount
        let pitches = Self.pitchCount
        let frameStride = arr.strides[1].intValue
        let pitchStride = arr.strides[2].intValue
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
        var out = [Float](repeating: 0, count: frames * pitches)
        for f in 0..<frames {
            let dstBase = f * pitches
            let srcBase = f * frameStride
            if pitchStride == 1 {
                // Fast path: contiguous pitch axis.
                let src = UnsafeBufferPointer(start: ptr.advanced(by: srcBase), count: pitches)
                out.withUnsafeMutableBufferPointer { dst in
                    _ = dst.baseAddress!.advanced(by: dstBase).update(from: src.baseAddress!, count: pitches)
                }
            } else {
                for p in 0..<pitches {
                    out[dstBase + p] = ptr[srcBase + p * pitchStride]
                }
            }
        }
        return out
    }

    private static func mean(of arr: MLMultiArray) -> Float {
        let count = arr.count
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
        var sum: Float = 0
        for i in 0..<count { sum += ptr[i] }
        return sum / Float(count)
    }
}
