//
//  AudioPitchDetector.swift
//  PianoCam
//
//  Real-time monophonic pitch detector using YIN over a sliding window of
//  microphone samples. Emits synthetic MIDIEvent.noteOn / .noteOff based on
//  pitch + onset, feeding the same `PianoState` that real MIDI hardware does.
//
//  Limitations: monophonic. Chords/dyads will lock onto a single note (often
//  the loudest fundamental). Polyphonic detection will require a model
//  (e.g. Basic Pitch).
//

import AVFoundation
import Accelerate
import Foundation

enum AudioPitchMode: String, CaseIterable, Identifiable {
    case yin = "Monophonic (YIN)"
    case basicPitch = "Polyphonic (Basic Pitch)"
    var id: String { rawValue }
}

@MainActor
final class AudioPitchDetector: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case unauthorized
        case running
        case failed(String)
    }

    var onEvent: ((MIDIEvent) -> Void)?

    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var state: State = .idle

    @Published var mode: AudioPitchMode = .basicPitch {
        didSet { handleModeChange(from: oldValue) }
    }
    private var basicPitch: BasicPitchInference?
    /// Live tunables that the SwiftUI panel mutates. Forwarded to the active
    /// `BasicPitchInference` instance.
    var basicPitchSettings = BasicPitchInference.Settings() {
        didSet { basicPitch?.settings = basicPitchSettings }
    }

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "pianocam.audio.capture")
    private let analysisQueue = DispatchQueue(label: "pianocam.audio.analysis", qos: .userInitiated)
    private var audioInput: AVCaptureDeviceInput?
    private let audioOutput = AVCaptureAudioDataOutput()

    private let windowLength = 2048           // YIN analysis window in samples
    private let analysisStride = 1024         // run YIN every N new samples
    private var sampleRate: Double = 44_100   // updated from device format
    private var ringBuffer: [Float] = []      // last `windowLength * 2` samples
    private var samplesSinceLastAnalysis: Int = 0

    // Note tracking
    private var currentNote: UInt8? = nil
    private var stabilityCount: Int = 0
    private var silenceCount: Int = 0
    private let stabilityNeeded = 2           // frames in a row before we emit
    private let silenceFramesUntilOff = 4     // frames of "no pitch" before note-off
    private var lastEmittedRMS: Float = 0

    static var availableInputs: [AVCaptureDevice] {
        if #available(macOS 14.0, *) {
            let s = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            return s.devices
        }
        return AVCaptureDevice.devices(for: .audio)
    }

    func start(device: AVCaptureDevice? = nil) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.state = .unauthorized
                    return
                }
                self.configure(device: device)
            }
        }
    }

    private func handleModeChange(from previous: AudioPitchMode) {
        guard previous != mode else { return }
        // Drop any held YIN note when moving to Basic Pitch (and vice versa).
        if let cur = currentNote {
            onEvent?(.noteOff(note: cur))
            currentNote = nil
        }
        basicPitch?.reset()

        if mode == .basicPitch && basicPitch == nil {
            do {
                let bp = try BasicPitchInference()
                bp.settings = basicPitchSettings
                bp.onEvent = { [weak self] event in
                    DispatchQueue.main.async { self?.onEvent?(event) }
                }
                basicPitch = bp
            } catch {
                NSLog("PianoCam: Basic Pitch unavailable — \(error.localizedDescription)")
                state = .failed("Basic Pitch unavailable: \(error.localizedDescription)")
                mode = .yin
            }
        }
    }

    func stop() {
        session.stopRunning()
        basicPitch?.reset()
        if let existing = audioInput {
            session.removeInput(existing)
            audioInput = nil
        }
        if let cur = currentNote {
            onEvent?(.noteOff(note: cur))
            currentNote = nil
        }
        ringBuffer.removeAll(keepingCapacity: true)
        samplesSinceLastAnalysis = 0
        state = .idle
    }

    private func configure(device explicit: AVCaptureDevice?) {
        let device = explicit ?? AVCaptureDevice.default(for: .audio) ?? Self.availableInputs.first
        guard let device else {
            state = .failed("No audio input device")
            return
        }

        session.beginConfiguration()
        if let existing = audioInput {
            session.removeInput(existing)
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            state = .failed("Couldn't open \(device.localizedName)")
            return
        }
        if session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        if !session.outputs.contains(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            } else {
                session.commitConfiguration()
                state = .failed("Cannot add audio output")
                return
            }
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        ringBuffer.removeAll(keepingCapacity: true)
        ringBuffer.reserveCapacity(windowLength * 2)
        currentNote = nil
        stabilityCount = 0
        silenceCount = 0
        state = .running
    }
}

extension AudioPitchDetector: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        guard let asbd = asbdPtr?.pointee else { return }
        let sr = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }
        let buf = audioBufferList.mBuffers
        guard buf.mNumberChannels > 0, let mData = buf.mData else { return }

        let bytesPerFrame = MemoryLayout<Float>.size * channels
        let frames = Int(buf.mDataByteSize) / bytesPerFrame
        let ptr = mData.assumingMemoryBound(to: Float.self)

        // Mix down to mono: take channel 0 of interleaved float samples.
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            mono[i] = ptr[i * channels]
        }

        analysisQueue.async { [weak self] in
            self?.ingest(mono: mono, sampleRate: sr)
        }
    }

    private nonisolated func ingest(mono: [Float], sampleRate sr: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.appendAndAnalyze(mono: mono, sampleRate: sr)
        }
    }

    private func appendAndAnalyze(mono: [Float], sampleRate sr: Double) {
        sampleRate = sr

        // Always feed Basic Pitch first when polyphonic mode is on.
        if mode == .basicPitch, let bp = basicPitch {
            bp.ingest(mono, sampleRate: sr)
        }

        ringBuffer.append(contentsOf: mono)
        // Keep the buffer bounded.
        let maxSize = windowLength * 2
        if ringBuffer.count > maxSize {
            ringBuffer.removeFirst(ringBuffer.count - maxSize)
        }

        // Update RMS for the level meter.
        var rms: Float = 0
        mono.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(mono.count))
        }
        inputLevel = min(1, rms * 30)

        samplesSinceLastAnalysis += mono.count
        guard samplesSinceLastAnalysis >= analysisStride,
              ringBuffer.count >= windowLength else { return }
        samplesSinceLastAnalysis = 0

        // YIN runs only in monophonic mode; Basic Pitch handles polyphonic
        // events via its own ingestion path.
        guard mode == .yin else { return }

        let window = Array(ringBuffer.suffix(windowLength))
        let detectedHz = Self.yin(window: window, sampleRate: sr)
        process(pitchHz: detectedHz, rms: rms)
    }

    /// State machine: stabilize → emit note-on/note-off into `onEvent`.
    private func process(pitchHz: Double?, rms: Float) {
        let onsetFloor: Float = 0.01

        guard let hz = pitchHz, hz.isFinite, hz > 20, rms > onsetFloor else {
            silenceCount += 1
            stabilityCount = 0
            if silenceCount >= silenceFramesUntilOff, let cur = currentNote {
                onEvent?(.noteOff(note: cur))
                currentNote = nil
            }
            return
        }
        silenceCount = 0

        let raw = 69 + 12 * log2(hz / 440)
        guard raw.isFinite else { return }
        let detectedNote = UInt8(clamping: Int(round(raw)))
        // Ignore out-of-range detections.
        guard (21...108).contains(detectedNote) else { return }

        if detectedNote == currentNote {
            stabilityCount = min(stabilityCount + 1, 100)
            return
        }
        // Different note candidate — wait for stability before switching.
        stabilityCount += 1
        if stabilityCount >= stabilityNeeded {
            if let prev = currentNote {
                onEvent?(.noteOff(note: prev))
            }
            let velocity = UInt8(min(127, max(50, Int(rms * 800))))
            onEvent?(.noteOn(note: detectedNote, velocity: velocity))
            currentNote = detectedNote
            stabilityCount = 0
            lastEmittedRMS = rms
        }
    }

    // MARK: - YIN

    /// Returns the detected fundamental frequency in Hz, or nil if no clear pitch.
    private static func yin(window: [Float], sampleRate: Double, threshold: Float = 0.12) -> Double? {
        let W = window.count
        let halfW = W / 2
        guard halfW > 32 else { return nil }

        var d = [Float](repeating: 0, count: halfW)

        // Difference function (squared diffs, sum over half-window).
        // O(W * halfW) — for W=2048 this is ~2M float ops / window, fine at ~22 Hz analysis rate.
        for tau in 1..<halfW {
            var sum: Float = 0
            var i = 0
            while i + tau < halfW {
                let diff = window[i] - window[i + tau]
                sum += diff * diff
                i += 1
            }
            d[tau] = sum
        }

        // Cumulative mean normalized difference.
        var dPrime = [Float](repeating: 1, count: halfW)
        var running: Float = 0
        for tau in 1..<halfW {
            running += d[tau]
            if running > 0 {
                dPrime[tau] = d[tau] / (running / Float(tau))
            }
        }

        // Find first dip below threshold.
        // Restrict tau range to plausible piano fundamentals (27 Hz … 4500 Hz).
        let minTau = max(2, Int(sampleRate / 4500))
        let maxTau = min(halfW - 1, Int(sampleRate / 27))
        var tau = minTau
        while tau < maxTau {
            if dPrime[tau] < threshold {
                // Walk down to local minimum.
                while tau + 1 < maxTau && dPrime[tau + 1] < dPrime[tau] {
                    tau += 1
                }
                // Parabolic interpolation for sub-sample accuracy.
                let x0 = max(tau - 1, 0)
                let x2 = min(tau + 1, halfW - 1)
                let s0 = dPrime[x0], s1 = dPrime[tau], s2 = dPrime[x2]
                let denom = 2 * (2 * s1 - s2 - s0)
                let betterTau: Double
                if denom != 0 {
                    betterTau = Double(tau) + Double(s2 - s0) / Double(denom)
                } else {
                    betterTau = Double(tau)
                }
                return sampleRate / betterTau
            }
            tau += 1
        }
        return nil
    }
}
