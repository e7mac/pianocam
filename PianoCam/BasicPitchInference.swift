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
    /// When each active note was triggered, used to enforce minHoldSeconds.
    private var noteOnTimes: [UInt8: TimeInterval] = [:]

    /// Probabilities at which we accept a note onset / continued note.
    private let onsetThreshold: Float = 0.50
    private let frameThreshold: Float = 0.20
    /// Fraction of recent frames that must be "active" for a sustained note.
    private let sustainedFraction: Float = 0.25
    /// Minimum time (seconds) a note stays lit after onset, regardless of
    /// whether the model still sees it. Mirrors a piano's natural decay tail.
    private let minHoldSeconds: TimeInterval = 0.5

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
        noteOnTimes.removeAll()
        ring.removeAll(keepingCapacity: true)
        samplesSinceLastInference = 0
    }

    // MARK: - Inference

    private var probedOutputs = false

    private func runInference(audio: [Float]) {
        do {
            // Peak-normalize the 2s window — Basic Pitch was trained on
            // normalized audio and underestimates note activity on quiet input.
            var peak: Float = 0
            for s in audio { let a = abs(s); if a > peak { peak = a } }
            var normalized = audio
            if peak > 0.001 {
                let gain = 0.9 / peak
                for i in 0..<normalized.count { normalized[i] *= gain }
            }

            let shape: [NSNumber] = [1, NSNumber(value: Self.modelWindowSamples), 1]
            let bytes = normalized.count * MemoryLayout<Float>.stride
            let data = NSMutableData(length: bytes)!
            normalized.withUnsafeBufferPointer { src in
                memcpy(data.mutableBytes, src.baseAddress, bytes)
            }
            let input = try ORTValue(tensorData: data, elementType: .float, shape: shape)

            let inputName = "serving_default_input_2:0"
            let outA = "StatefulPartitionedCall:1"
            let outB = "StatefulPartitionedCall:2"

            let outputs = try session.run(
                withInputs: [inputName: input],
                outputNames: Set([outA, outB]),
                runOptions: nil
            )

            guard let valA = outputs[outA], let valB = outputs[outB] else { return }
            let dataA = try valA.tensorData() as Data
            let dataB = try valB.tensorData() as Data

            let frameCount = 172, pitchCount = 88
            guard dataA.count == frameCount * pitchCount * MemoryLayout<Float>.size,
                  dataB.count == dataA.count else {
                NSLog("PianoCam basicpitch: unexpected output sizes")
                return
            }
            let probsA = Self.toFloats(dataA)
            let probsB = Self.toFloats(dataB)

            // Probe which output is "note" (sustained) vs "onset" (sparse).
            // Onset peaks are sparse; note remains high for the whole note's
            // duration. So `note` has a higher mean for a given pitch's time
            // series than `onset` does. Use mean-of-active-frames as a hint.
            let aMean = probsA.reduce(0, +) / Float(probsA.count)
            let bMean = probsB.reduce(0, +) / Float(probsB.count)
            let noteProbs: [Float]
            let onsetProbs: [Float]
            if aMean >= bMean {
                noteProbs = probsA; onsetProbs = probsB
            } else {
                noteProbs = probsB; onsetProbs = probsA
            }
            if !probedOutputs {
                probedOutputs = true
                NSLog("PianoCam basicpitch: outputs probed — :1 mean=\(String(format: "%.3f", aMean)) :2 mean=\(String(format: "%.3f", bMean)) → \(aMean >= bMean ? ":1=note,:2=onset" : ":1=onset,:2=note")")
            }

            // Analyze the last ~256 ms (22 frames at 86 fps).
            let tailFrames = 22
            let startFrame = max(0, frameCount - tailFrames)
            let totalTail = frameCount - startFrame

            // Diagnostic: log peak probabilities seen in the recent window.
            var maxNote: Float = 0
            var maxOnset: Float = 0
            for f in startFrame..<frameCount {
                for p in 0..<pitchCount {
                    let i = f * pitchCount + p
                    if noteProbs[i] > maxNote { maxNote = noteProbs[i] }
                    if onsetProbs[i] > maxOnset { maxOnset = onsetProbs[i] }
                }
            }
            if Int.random(in: 0..<5) == 0 {
                NSLog("PianoCam basicpitch: peak note=\(String(format: "%.2f", maxNote)) onset=\(String(format: "%.2f", maxOnset)) audioPeak=\(String(format: "%.3f", peak))")
            }

            var detectedActive: Set<UInt8> = []
            var detectedOnsets: [UInt8: Float] = [:]   // note -> peak onset score
            for p in 0..<pitchCount {
                var activeCount = 0
                var maxOnset: Float = 0
                for f in startFrame..<frameCount {
                    let i = f * pitchCount + p
                    if noteProbs[i] > frameThreshold { activeCount += 1 }
                    if onsetProbs[i] > maxOnset { maxOnset = onsetProbs[i] }
                }
                let activeFraction = Float(activeCount) / Float(totalTail)
                let midi = UInt8(21 + p)
                // A note is "active" (kept lit) if either:
                //   • frame probability is sustained, OR
                //   • a strong onset just happened (so the note is freshly struck).
                if activeFraction >= sustainedFraction || maxOnset >= onsetThreshold {
                    detectedActive.insert(midi)
                }
                // Only fire note-on for clearly-onset notes.
                if maxOnset >= onsetThreshold {
                    detectedOnsets[midi] = maxOnset
                }
            }

            // Octave-suppression: if both N and N+12 are detected and one is
            // much weaker, drop the weaker. Helps with the second-harmonic
            // false positive that vanilla Basic Pitch sometimes produces.
            for note in Array(detectedActive) {
                let upper = note &+ 12
                guard detectedActive.contains(upper) else { continue }
                let lowerOnset = detectedOnsets[note] ?? 0
                let upperOnset = detectedOnsets[upper] ?? 0
                if upperOnset < lowerOnset * 0.6 {
                    detectedActive.remove(upper)
                    detectedOnsets.removeValue(forKey: upper)
                }
            }

            // Emit note-off only after the minimum hold time has elapsed.
            let now = Date().timeIntervalSince1970
            let toTurnOff = activeNotes.subtracting(detectedActive)
            for note in toTurnOff {
                let onTime = noteOnTimes[note] ?? 0
                if now - onTime >= minHoldSeconds {
                    onEvent?(.noteOff(note: note))
                    activeNotes.remove(note)
                    noteOnTimes.removeValue(forKey: note)
                }
            }
            // Emit note-on for any note with a fresh strong onset.
            for (note, _) in detectedOnsets {
                if !activeNotes.contains(note) {
                    onEvent?(.noteOn(note: note, velocity: 100))
                    activeNotes.insert(note)
                    noteOnTimes[note] = now
                }
            }
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
