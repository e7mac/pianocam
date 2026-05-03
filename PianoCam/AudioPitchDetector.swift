//
//  AudioPitchDetector.swift
//  PianoCam
//
//  Captures microphone audio and analyzes it for piano pitches in real time.
//  Stub detector for now: emits a synthetic note-on for the loudest band when
//  the input exceeds an onset threshold. Will be replaced by Basic Pitch
//  (CoreML) once the pipeline is wired end-to-end.
//

import AVFoundation
import Accelerate
import Foundation

@MainActor
final class AudioPitchDetector: ObservableObject {
    enum State: Equatable {
        case idle
        case unauthorized
        case running
        case failed(String)
    }

    /// Called on the audio queue with synthetic MIDI events.
    var onEvent: ((MIDIEvent) -> Void)?

    /// Lightweight RMS for a UI level meter (0…1).
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var state: State = .idle

    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "pianocam.pitch", qos: .userInitiated)

    /// Notes currently considered "on" by the detector. Tracked so we can
    /// emit clean note-off events when a note disappears.
    private var activeStubNotes: Set<UInt8> = []
    private var lastOnsetTime: TimeInterval = 0

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.state = .unauthorized
                    return
                }
                self.installTapAndStart()
            }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        for note in activeStubNotes {
            onEvent?(.noteOff(note: note))
        }
        activeStubNotes.removeAll()
        state = .idle
    }

    private func installTapAndStart() {
        let input = engine.inputNode
        // On macOS, the input node's output format is the canonical place to
        // ask for what's flowing into the rest of the engine.
        let format = input.outputFormat(forBus: 0)
        NSLog("PianoCam audio: format channels=\(format.channelCount) sampleRate=\(format.sampleRate)")
        guard format.channelCount > 0, format.sampleRate > 0 else {
            state = .failed("Input format unavailable (channels=\(format.channelCount), sr=\(format.sampleRate))")
            return
        }

        // 4096 samples ≈ 93 ms at 44.1 kHz / 85 ms at 48 kHz.
        var tapCount = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            tapCount += 1
            if tapCount <= 3 {
                NSLog("PianoCam audio: tap fired #\(tapCount) frames=\(buffer.frameLength)")
            }
            self?.analysisQueue.async {
                self?.analyze(buffer: buffer, sampleRate: format.sampleRate)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            state = .running
            NSLog("PianoCam audio: engine started")
        } catch {
            NSLog("PianoCam audio: engine.start failed — \(error)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Stub analyzer

    /// For now: detect loud transients and emit a single C4 note-on. This
    /// confirms the audio pipeline is alive end-to-end before we plug in a
    /// real model. Replaced wholesale by Basic Pitch later.
    private func analyze(buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))

        // Bump to a usable visual range — typical room mic RMS is ~0.005,
        // shouting is ~0.1; multiply so the meter actually shows movement.
        let scaled = min(1.0, rms * 30)
        DispatchQueue.main.async { [weak self] in
            self?.inputLevel = scaled
        }
        // Log every ~30 frames so we can see live RMS in Console without spam.
        if Int.random(in: 0..<30) == 0 {
            NSLog("PianoCam audio: rms=\(String(format: "%.4f", rms)) scaled=\(String(format: "%.2f", scaled))")
        }

        let onsetThreshold: Float = 0.05
        let now = Date().timeIntervalSince1970
        let cooldown = 0.18  // seconds between stub note-ons
        if rms > onsetThreshold && now - lastOnsetTime > cooldown {
            lastOnsetTime = now
            DispatchQueue.main.async { [weak self] in
                self?.fireStubNote()
            }
        }
    }

    private func fireStubNote() {
        let note: UInt8 = 60  // middle C
        if activeStubNotes.contains(note) {
            onEvent?(.noteOff(note: note))
            activeStubNotes.remove(note)
        }
        let velocity = UInt8(min(127, max(40, Int(inputLevel * 200))))
        onEvent?(.noteOn(note: note, velocity: velocity))
        activeStubNotes.insert(note)

        // Auto-release after 250 ms so the visual matches a piano-ish envelope.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.activeStubNotes.remove(note) != nil {
                self.onEvent?(.noteOff(note: note))
            }
        }
    }
}
