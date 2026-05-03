//
//  BasicPitchInference.swift
//  PianoCam
//
//  Polyphonic piano transcription using Spotify's Basic Pitch model via
//  Microsoft's ONNX Runtime. Maintains a 2-second sliding audio buffer at
//  22050 Hz, runs inference periodically on the most recent window, and
//  emits synthetic note-on / note-off events into the same `PianoState`
//  pipeline used by MIDI hardware.
//

import Foundation
import AVFoundation
import OnnxRuntimeBindings

final class BasicPitchInference {
    /// Synthetic MIDI events from the model. Called on the inference queue.
    var onEvent: ((MIDIEvent) -> Void)?
    /// Diagnostics — last-inference info; nil until the first run.
    var onStatus: ((String) -> Void)?

    static let modelSampleRate: Double = 22_050
    static let modelWindowSamples = 43_844           // 2 seconds @ 22.05 kHz

    private let env: ORTEnv
    private let session: ORTSession
    private let inferenceQueue = DispatchQueue(label: "pianocam.basicpitch", qos: .userInitiated)

    /// Audio at the model's native sample rate (22050 Hz).
    private var ring: [Float] = []
    private var samplesSinceLastInference: Int = 0
    private let inferenceStride = 5_512              // ~250 ms at 22050 Hz
    private var inferring = false

    /// Notes currently considered "on" by the model (set of MIDI numbers).
    private var activeNotes: Set<UInt8> = []

    /// Probabilities at which we accept a note onset / continued note.
    private let onsetThreshold: Float = 0.55
    private let frameThreshold: Float = 0.40

    init() throws {
        env = try ORTEnv(loggingLevel: .warning)
        guard let url = Bundle.main.url(forResource: "BasicPitch", withExtension: "onnx") else {
            throw NSError(domain: "PianoCam", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "BasicPitch.onnx not in app bundle"
            ])
        }
        let opts = try ORTSessionOptions()
        // Try to enable the CoreML execution provider (Apple Neural Engine
        // when available, falls back to GPU/CPU otherwise).
        let coreMLOptions: [String: String] = ["use_cpu_only": "0"]
        try? opts.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions())
        _ = coreMLOptions
        session = try ORTSession(env: env, modelPath: url.path, sessionOptions: opts)
        ring.reserveCapacity(Self.modelWindowSamples * 2)
        NSLog("PianoCam basicpitch: model loaded")
    }

    /// Append fresh samples (at any source sample rate) and possibly run inference.
    func ingest(_ samples: [Float], sampleRate srcSR: Double) {
        let resampled = Self.linearResample(samples, from: srcSR, to: Self.modelSampleRate)
        ring.append(contentsOf: resampled)
        let cap = Self.modelWindowSamples * 2
        if ring.count > cap {
            ring.removeFirst(ring.count - cap)
        }
        samplesSinceLastInference += resampled.count
        guard samplesSinceLastInference >= inferenceStride,
              ring.count >= Self.modelWindowSamples,
              !inferring else { return }
        samplesSinceLastInference = 0
        inferring = true
        let snapshot = Array(ring.suffix(Self.modelWindowSamples))
        inferenceQueue.async { [weak self] in
            self?.runInference(audio: snapshot)
            self?.inferring = false
        }
    }

    /// Reset the in-flight state; emit note-offs for anything still held.
    func reset() {
        for note in activeNotes { onEvent?(.noteOff(note: note)) }
        activeNotes.removeAll()
        ring.removeAll(keepingCapacity: true)
        samplesSinceLastInference = 0
    }

    // MARK: - Inference

    private func runInference(audio: [Float]) {
        do {
            let shape: [NSNumber] = [1, NSNumber(value: Self.modelWindowSamples), 1]
            let bytes = audio.count * MemoryLayout<Float>.stride
            let data = NSMutableData(length: bytes)!
            audio.withUnsafeBufferPointer { src in
                memcpy(data.mutableBytes, src.baseAddress, bytes)
            }
            let input = try ORTValue(tensorData: data, elementType: .float, shape: shape)

            let inputName = "serving_default_input_2:0"
            let noteOutputName = "StatefulPartitionedCall:1"
            let onsetOutputName = "StatefulPartitionedCall:2"

            let outputs = try session.run(
                withInputs: [inputName: input],
                outputNames: Set([noteOutputName, onsetOutputName]),
                runOptions: nil
            )

            guard let noteValue = outputs[noteOutputName],
                  let onsetValue = outputs[onsetOutputName] else { return }

            let noteData = try noteValue.tensorData() as Data
            let onsetData = try onsetValue.tensorData() as Data

            // Both tensors are (1, 172, 88) Float32 = 60384 bytes each.
            let frameCount = 172
            let pitchCount = 88
            guard noteData.count == frameCount * pitchCount * MemoryLayout<Float>.size,
                  onsetData.count == noteData.count else {
                NSLog("PianoCam basicpitch: unexpected output sizes note=\(noteData.count) onset=\(onsetData.count)")
                return
            }
            let noteProbs = Self.toFloats(noteData)
            let onsetProbs = Self.toFloats(onsetData)

            // Look at the LAST 22 frames (~256 ms of audio) so we react to
            // recent events; older frames are duplicates from the previous
            // inference window.
            let tailFrames = 22
            let startFrame = max(0, frameCount - tailFrames)

            // Aggregate: a pitch is "active" if any of the last frames'
            // note prob exceeds threshold; an "onset" if any of the last
            // frames' onset prob exceeds the onset threshold.
            var detectedActive: Set<UInt8> = []
            var detectedOnsets: Set<UInt8> = []
            for p in 0..<pitchCount {
                var maxNote: Float = 0
                var maxOnset: Float = 0
                for f in startFrame..<frameCount {
                    let i = f * pitchCount + p
                    if noteProbs[i] > maxNote { maxNote = noteProbs[i] }
                    if onsetProbs[i] > maxOnset { maxOnset = onsetProbs[i] }
                }
                let midi = UInt8(21 + p)  // pitch index 0 = MIDI 21 (A0)
                if maxNote > frameThreshold { detectedActive.insert(midi) }
                if maxOnset > onsetThreshold { detectedOnsets.insert(midi) }
            }

            // Emit note-on for new onsets; note-off for notes that disappeared.
            let toTurnOff = activeNotes.subtracting(detectedActive)
            for note in toTurnOff {
                onEvent?(.noteOff(note: note))
                activeNotes.remove(note)
            }
            for note in detectedOnsets {
                if !activeNotes.contains(note) {
                    onEvent?(.noteOn(note: note, velocity: 100))
                    activeNotes.insert(note)
                }
            }
            // Notes that the frame model says are still active, but that we
            // somehow lost — leave them; an onset will re-trigger.

            onStatus?("active=\(activeNotes.count)")
        } catch {
            NSLog("PianoCam basicpitch: inference failed — \(error)")
        }
    }

    // MARK: - Helpers

    private static func toFloats(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw -> [Float] in
            let ptr = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: ptr.baseAddress, count: count))
        }
    }

    /// Cheap linear-interpolation resampler. Good enough for piano work where
    /// we're decimating ~44.1 kHz mic input down to 22.05 kHz.
    private static func linearResample(_ src: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        if abs(srcRate - dstRate) < 1 { return src }
        let ratio = srcRate / dstRate
        let outCount = Int(Double(src.count) / ratio)
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let i0 = Int(pos)
            let i1 = min(i0 + 1, src.count - 1)
            let frac = Float(pos - Double(i0))
            out[i] = src[i0] * (1 - frac) + src[i1] * frac
        }
        return out
    }
}
