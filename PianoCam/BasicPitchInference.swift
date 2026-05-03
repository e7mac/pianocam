//
//  BasicPitchInference.swift
//  PianoCam
//
//  Live polyphonic piano transcription using Spotify's Basic Pitch model.
//  Maintains a 2-second sliding audio buffer at 22050 Hz, runs inference
//  periodically on the most recent window via `BasicPitchModel`, and emits
//  synthetic note-on / note-off events into the same `PianoState` pipeline
//  used by MIDI hardware.
//

import Foundation
import AVFoundation

final class BasicPitchInference {
    /// Synthetic MIDI events from the model. Called on the inference queue.
    var onEvent: ((MIDIEvent) -> Void)?
    /// Diagnostics — last-inference info; nil until the first run.
    var onStatus: ((String) -> Void)?

    private let model: BasicPitchModel
    private let inferenceQueue = DispatchQueue(label: "pianocam.basicpitch", qos: .userInitiated)

    /// Audio at the model's native sample rate (22050 Hz).
    private var ring: [Float] = []
    private var samplesSinceLastInference: Int = 0
    private var inferring = false
    private var backPressureSkips = 0

    /// Inference cadence in samples at 22050 Hz. Lower = lower latency, higher
    /// CPU/ANE load. If a window's inference doesn't finish before the next
    /// stride boundary, the next tick is skipped (back-pressure via `inferring`).
    private var inferenceStride: Int { Int(settings.inferenceIntervalSeconds * BasicPitchModel.sampleRate) }
    /// Tail frames analyzed after each inference, sized to match the stride so
    /// every onset is detected exactly once across consecutive inferences.
    private var tailFrames: Int {
        let s = max(1, Int((Double(inferenceStride) / Double(BasicPitchModel.windowSamples) * Double(BasicPitchModel.frameCount)).rounded()))
        return min(BasicPitchModel.frameCount, s + 1)   // +1 frame slack to avoid boundary races
    }

    /// Notes currently considered "on" by the model (set of MIDI numbers).
    private var activeNotes: Set<UInt8> = []
    /// When each active note was triggered, used to enforce minHoldSeconds.
    private var noteOnTimes: [UInt8: TimeInterval] = [:]

    struct Settings {
        var onsetThreshold: Float = 0.50
        var frameThreshold: Float = 0.20
        var sustainedFraction: Float = 0.25
        var minHoldSeconds: TimeInterval = 0.12
        /// Inference cadence — lower = lower latency, higher CPU. Average
        /// note-on latency ≈ this/2 + ~30 ms (model compute) + ~30–50 ms
        /// (model's inherent post-onset context). On Apple Silicon with the
        /// ANE, 0.08–0.15 s is comfortable.
        var inferenceIntervalSeconds: Double = 0.08
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
        self.model = try BasicPitchModel()
        ring.reserveCapacity(BasicPitchModel.windowSamples * 2)
    }

    /// Append fresh samples (at any source sample rate) and possibly run inference.
    func ingest(_ samples: [Float], sampleRate srcSR: Double) {
        let resampled = Self.linearResample(samples, from: srcSR, to: BasicPitchModel.sampleRate)

        // Speech rejection: if the just-arrived chunk looks like speech, drop it.
        // We do *not* reset state — brief speech overlapping piano shouldn't kill
        // the active notes; the ring buffer simply doesn't grow during the speech.
        if settings.rejectSpeech, !resampled.isEmpty,
           VoiceActivityDetector.isSpeech(resampled, sampleRate: BasicPitchModel.sampleRate) {
            return
        }

        ring.append(contentsOf: resampled)
        let cap = BasicPitchModel.windowSamples * 2
        if ring.count > cap {
            ring.removeFirst(ring.count - cap)
        }
        samplesSinceLastInference += resampled.count
        guard samplesSinceLastInference >= inferenceStride,
              ring.count >= BasicPitchModel.windowSamples else { return }
        // Back-pressure: if the previous inference hasn't finished, skip this
        // tick instead of queuing — but log it once in a while so the user
        // notices when the cadence is too aggressive for the device.
        if inferring {
            backPressureSkips += 1
            if backPressureSkips % 10 == 1 {
                NSLog("PianoCam basicpitch: back-pressure — \(backPressureSkips) skipped ticks; consider raising inferenceIntervalSeconds")
            }
            return
        }
        samplesSinceLastInference = 0
        inferring = true
        let snapshot = Array(ring.suffix(BasicPitchModel.windowSamples))
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

    private func runInference(audio: [Float]) {
        // Peak-normalize the 2 s window — Basic Pitch was trained on
        // normalized audio and underestimates note activity on quiet input.
        var peak: Float = 0
        for s in audio { let a = abs(s); if a > peak { peak = a } }
        var normalized = audio
        if peak > 0.001 {
            let gain: Float = 0.9 / peak
            for i in 0..<normalized.count { normalized[i] *= gain }
        }
        do {
            let (note, onset) = try model.infer(audio: normalized)
            processOutput(notes: note, onsets: onset, audioPeak: peak)
        } catch {
            NSLog("PianoCam basicpitch: inference failed — \(error)")
        }
    }

    private func processOutput(notes: [Float], onsets: [Float], audioPeak: Float) {
        let frameCount = BasicPitchModel.frameCount
        let pitchCount = BasicPitchModel.pitchCount
        // Analyze just enough recent frames to cover one inference stride;
        // larger tails would re-detect onsets we already emitted last tick.
        let startFrame = max(0, frameCount - tailFrames)

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
                let nVal = notes[f * pitchCount + p]
                let oVal = onsets[f * pitchCount + p]
                if nVal > frameThr { activeCount += 1 }
                if oVal > maxOnsetInTail { maxOnsetInTail = oVal }
                if oVal > diagMaxOnset { diagMaxOnset = oVal }
                if nVal > diagMaxNote { diagMaxNote = nVal }

                // Local-maximum onset peak picking — looking back to the
                // previous frame in the same inference window (which is fine
                // because the model output covers the full 2 s; only emission
                // is restricted to the tail).
                let prevVal: Float = (f > 0) ? onsets[(f - 1) * pitchCount + p] : 0
                let nextVal: Float = (f + 1 < frameCount) ? onsets[(f + 1) * pitchCount + p] : 0
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

        // Note-on / re-trigger: each peak-picked onset is a fresh attack.
        // BUT — during a sustain, the model's onset prob has small local
        // maxima (harmonic / noise) that can cross threshold without being
        // a real attack. Suppress retriggers within 120 ms of the previous
        // note-on for the same pitch; that's still well below human-playable
        // trill speeds (~125 ms / 8 Hz) but kills the noise retriggers.
        let retriggerMinGap: TimeInterval = 0.12
        newOnsets.sort { $0.time < $1.time }
        for onset in newOnsets {
            if let lastOn = noteOnTimes[onset.note], now - lastOn < retriggerMinGap {
                continue
            }
            if activeNotes.contains(onset.note) {
                onEvent?(.noteOff(note: onset.note))
                activeNotes.remove(onset.note)
            }
            onEvent?(.noteOn(note: onset.note, velocity: Self.velocityFromOnset(onset.score)))
            activeNotes.insert(onset.note)
            noteOnTimes[onset.note] = now
        }

        NSLog("PianoCam basicpitch: peak note=\(String(format: "%.2f", diagMaxNote)) onset=\(String(format: "%.2f", diagMaxOnset)) audioPeak=\(String(format: "%.3f", audioPeak)) active=\(activeNotes.count) newOnsets=\(newOnsets.count)")
        onStatus?("active=\(activeNotes.count)")
    }

    // MARK: - Helpers

    /// Map onset prob → MIDI velocity. Onset prob is correlated with attack
    /// strength: a strong piano attack gives prob ≥ 0.9; soft notes ≈ 0.5.
    /// Linear-map [0.4, 1.0] → [40, 127] and clamp.
    static func velocityFromOnset(_ p: Float) -> UInt8 {
        let v = Int(40.0 + (max(0, p - 0.4) / 0.6) * 87.0)
        return UInt8(min(127, max(1, v)))
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
