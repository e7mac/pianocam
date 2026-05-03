//
//  BasicPitchInference.swift
//  PianoCam
//
//  Polyphonic piano transcription using Spotify's Basic Pitch model via
//  native CoreML. Maintains a 2-second sliding audio buffer at 22050 Hz,
//  runs inference periodically on the most recent window, and emits
//  synthetic note-on / note-off events into the same `PianoState` pipeline
//  used by MIDI hardware.
//

import Foundation
import AVFoundation
import CoreML

final class BasicPitchInference {
    /// Synthetic MIDI events from the model. Called on the inference queue.
    var onEvent: ((MIDIEvent) -> Void)?
    /// Diagnostics — last-inference info; nil until the first run.
    var onStatus: ((String) -> Void)?

    static let modelSampleRate: Double = 22_050
    static let modelWindowSamples = 43_844           // 2 s @ 22.05 kHz
    static let modelFrames = 172                     // 86 fps for 2 s
    static let modelPitches = 88

    private let model: MLModel
    private let inputName: String
    private let outputNames: [String]
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

    struct Settings {
        var onsetThreshold: Float = 0.50
        var frameThreshold: Float = 0.20
        var sustainedFraction: Float = 0.25
        var minHoldSeconds: TimeInterval = 0.12
        /// When true, audio chunks classified as speech are dropped before
        /// reaching the model. Cuts vocal-induced false positives, but the
        /// existing VAD over-rejects at small live-buffer sizes — leave off
        /// until VAD is retuned for 22.05 kHz / ~46 ms chunks.
        var rejectSpeech: Bool = false
    }

    /// Live-updatable detection settings — mutated from the main thread,
    /// read by the inference thread. Atomic-ish (Float/Double assignments).
    var settings = Settings()

    init() throws {
        // At runtime, Xcode ships a compiled `.mlmodelc`. Fall back to the raw
        // `.mlpackage` for projects that haven't yet rebuilt.
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
        ring.reserveCapacity(Self.modelWindowSamples * 2)
        NSLog("PianoCam basicpitch: CoreML loaded — input=\(inName) outputs=\(outputNames)")
    }

    /// Append fresh samples (at any source sample rate) and possibly run inference.
    func ingest(_ samples: [Float], sampleRate srcSR: Double) {
        let resampled = Self.linearResample(samples, from: srcSR, to: Self.modelSampleRate)

        // Speech rejection: if the just-arrived chunk looks like speech, drop it.
        // We do *not* reset state — brief speech overlapping piano shouldn't kill
        // the active notes; the ring buffer simply doesn't grow during the speech.
        if settings.rejectSpeech, !resampled.isEmpty,
           VoiceActivityDetector.isSpeech(resampled, sampleRate: Self.modelSampleRate) {
            return
        }

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
    private var noteOutputName: String?
    private var onsetOutputName: String?

    private func runInference(audio: [Float]) {
        do {
            // Peak-normalize the 2 s window — Basic Pitch was trained on
            // normalized audio and underestimates note activity on quiet input.
            var peak: Float = 0
            for s in audio { let a = abs(s); if a > peak { peak = a } }
            var normalized = audio
            if peak > 0.001 {
                let gain: Float = 0.9 / peak
                for i in 0..<normalized.count { normalized[i] *= gain }
            }

            let arr = try MLMultiArray(
                shape: [1, NSNumber(value: Self.modelWindowSamples), 1],
                dataType: .float32
            )
            let dst = arr.dataPointer.bindMemory(
                to: Float.self, capacity: Self.modelWindowSamples
            )
            normalized.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: Self.modelWindowSamples)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: arr])
            let out = try model.prediction(from: provider)

            // Of the (up to) 3 outputs, the two with shape (1, 172, 88) are
            // note + onset. Probe by mean: the sustained note-prob map has a
            // higher mean than the sparse onset map.
            var pitchOutputs: [(name: String, arr: MLMultiArray)] = []
            for name in outputNames {
                guard let v = out.featureValue(for: name)?.multiArrayValue else { continue }
                if v.shape.count == 3, v.shape[2].intValue == Self.modelPitches {
                    pitchOutputs.append((name, v))
                }
            }
            guard pitchOutputs.count >= 2 else {
                NSLog("PianoCam basicpitch: unexpected pitch-output count \(pitchOutputs.count)")
                return
            }
            if !probedOutputs {
                let m0 = Self.mean(of: pitchOutputs[0].arr)
                let m1 = Self.mean(of: pitchOutputs[1].arr)
                if m0 >= m1 {
                    noteOutputName = pitchOutputs[0].name
                    onsetOutputName = pitchOutputs[1].name
                } else {
                    noteOutputName = pitchOutputs[1].name
                    onsetOutputName = pitchOutputs[0].name
                }
                probedOutputs = true
                NSLog("PianoCam basicpitch: probed — note=\(noteOutputName!) (mean=\(String(format: "%.3f", m0 >= m1 ? m0 : m1))), onset=\(onsetOutputName!) (mean=\(String(format: "%.3f", m0 >= m1 ? m1 : m0))) shape=\(pitchOutputs[0].arr.shape) strides=\(pitchOutputs[0].arr.strides)")
            }
            guard let nName = noteOutputName, let oName = onsetOutputName,
                  let noteArr = out.featureValue(for: nName)?.multiArrayValue,
                  let onsetArr = out.featureValue(for: oName)?.multiArrayValue else { return }

            processOutput(noteArr: noteArr, onsetArr: onsetArr, audioPeak: peak)
        } catch {
            NSLog("PianoCam basicpitch: inference failed — \(error)")
        }
    }

    private func processOutput(noteArr: MLMultiArray, onsetArr: MLMultiArray, audioPeak: Float) {
        let frameCount = Self.modelFrames
        let pitchCount = Self.modelPitches
        // Analyze the most-recent ~stride frames (250 ms ≈ 22 frames @ 86 fps).
        let tailFrames = 22
        let startFrame = max(0, frameCount - tailFrames)

        let nPtr = noteArr.dataPointer.bindMemory(to: Float.self, capacity: noteArr.count)
        let oPtr = onsetArr.dataPointer.bindMemory(to: Float.self, capacity: onsetArr.count)
        // CoreML may not use contiguous strides for ANE-optimized models — read them.
        let nFrameStride = noteArr.strides[1].intValue
        let nPitchStride = noteArr.strides[2].intValue
        let oFrameStride = onsetArr.strides[1].intValue
        let oPitchStride = onsetArr.strides[2].intValue

        let onsetThr = settings.onsetThreshold
        let frameThr = settings.frameThreshold
        let sustainedFrac = settings.sustainedFraction

        var detectedSustained: Set<UInt8> = []
        var peakOnsetByPitch: [UInt8: Float] = [:]
        // Each entry is one detected attack; multiple per pitch are allowed
        // (e.g., trills). Sorted by time before being emitted so retriggers
        // come out in chronological order.
        var newOnsets: [(time: Int, note: UInt8, score: Float)] = []

        var diagMaxOnset: Float = 0
        var diagMaxNote: Float = 0

        for p in 0..<pitchCount {
            var activeCount = 0
            var maxOnsetInTail: Float = 0
            for f in startFrame..<frameCount {
                let nVal = nPtr[f * nFrameStride + p * nPitchStride]
                let oVal = oPtr[f * oFrameStride + p * oPitchStride]
                if nVal > frameThr { activeCount += 1 }
                if oVal > maxOnsetInTail { maxOnsetInTail = oVal }
                if oVal > diagMaxOnset { diagMaxOnset = oVal }
                if nVal > diagMaxNote { diagMaxNote = nVal }

                // Local-maximum onset peak picking — looking back to the
                // previous frame in the same inference window (which is fine
                // because the model output covers the full 2 s; only emission
                // is restricted to the tail).
                let prevVal: Float = (f > 0) ? oPtr[(f - 1) * oFrameStride + p * oPitchStride] : 0
                let nextVal: Float = (f + 1 < frameCount) ? oPtr[(f + 1) * oFrameStride + p * oPitchStride] : 0
                if oVal > onsetThr, oVal > prevVal, oVal >= nextVal {
                    newOnsets.append((time: f, note: UInt8(21 + p), score: oVal))
                }
            }
            let activeFraction = Float(activeCount) / Float(frameCount - startFrame)
            let midi = UInt8(21 + p)
            if activeFraction >= sustainedFrac || maxOnsetInTail >= onsetThr {
                detectedSustained.insert(midi)
            }
            if maxOnsetInTail >= onsetThr {
                peakOnsetByPitch[midi] = maxOnsetInTail
            }
        }

        // Octave-suppression: if both N and N+12 detected and upper is much
        // weaker, drop the upper (Basic Pitch's second-harmonic FP).
        for note in Array(detectedSustained) {
            let upper = note &+ 12
            guard detectedSustained.contains(upper) else { continue }
            let lowerOnset = peakOnsetByPitch[note] ?? 0
            let upperOnset = peakOnsetByPitch[upper] ?? 0
            if upperOnset < lowerOnset * 0.6 {
                detectedSustained.remove(upper)
                peakOnsetByPitch.removeValue(forKey: upper)
                newOnsets.removeAll { $0.note == upper }
            }
        }

        let now = Date().timeIntervalSince1970

        // Note-off: notes that are no longer sustained, past their min-hold.
        let toTurnOff = activeNotes.subtracting(detectedSustained)
        for note in toTurnOff {
            let onTime = noteOnTimes[note] ?? 0
            if now - onTime >= settings.minHoldSeconds {
                onEvent?(.noteOff(note: note))
                activeNotes.remove(note)
                noteOnTimes.removeValue(forKey: note)
            }
        }

        // Note-on / re-trigger: each peak-picked onset is a fresh attack. If
        // the pitch is already active, emit a note-off first so the host sees
        // the retrigger rather than a single sustained note.
        newOnsets.sort { $0.time < $1.time }
        for onset in newOnsets {
            if activeNotes.contains(onset.note) {
                onEvent?(.noteOff(note: onset.note))
                activeNotes.remove(onset.note)
            }
            onEvent?(.noteOn(note: onset.note, velocity: 100))
            activeNotes.insert(onset.note)
            noteOnTimes[onset.note] = now
        }

        NSLog("PianoCam basicpitch: peak note=\(String(format: "%.2f", diagMaxNote)) onset=\(String(format: "%.2f", diagMaxOnset)) audioPeak=\(String(format: "%.3f", audioPeak)) active=\(activeNotes.count) newOnsets=\(newOnsets.count)")
        onStatus?("active=\(activeNotes.count)")
    }

    // MARK: - Helpers

    private static func mean(of arr: MLMultiArray) -> Float {
        let count = arr.count
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
        var sum: Float = 0
        for i in 0..<count { sum += ptr[i] }
        return sum / Float(count)
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
