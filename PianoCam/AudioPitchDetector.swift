//
//  AudioPitchDetector.swift
//  PianoCam
//
//  Captures microphone audio via AVCaptureSession (so the device is
//  pickable, unlike AVAudioEngine which uses the system default) and runs
//  a pitch analyzer in real time. Stub detector for now: emits middle-C
//  on loud transients to verify the pipeline. Will be replaced by Basic
//  Pitch (CoreML) once the pipeline is verified end-to-end.
//

import AVFoundation
import Accelerate
import Foundation

@MainActor
final class AudioPitchDetector: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case unauthorized
        case running
        case failed(String)
    }

    /// Synthetic MIDI events emitted from analysis.
    var onEvent: ((MIDIEvent) -> Void)?

    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var state: State = .idle

    private let session = AVCaptureSession()
    private let analysisQueue = DispatchQueue(label: "pianocam.pitch", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "pianocam.pitch.capture")
    private var audioInput: AVCaptureDeviceInput?
    private let audioOutput = AVCaptureAudioDataOutput()

    private var activeStubNotes: Set<UInt8> = []
    private var lastOnsetTime: TimeInterval = 0
    private var tapCount = 0

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

    /// Start capture using `device` (or the default if nil).
    func start(device: AVCaptureDevice? = nil) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    NSLog("PianoCam audio: permission denied")
                    self.state = .unauthorized
                    return
                }
                self.configure(device: device)
            }
        }
    }

    func stop() {
        session.stopRunning()
        if let existing = audioInput {
            session.removeInput(existing)
            audioInput = nil
        }
        for note in activeStubNotes { onEvent?(.noteOff(note: note)) }
        activeStubNotes.removeAll()
        state = .idle
        NSLog("PianoCam audio: stopped")
    }

    private func configure(device explicit: AVCaptureDevice?) {
        let device = explicit ?? AVCaptureDevice.default(for: .audio) ?? Self.availableInputs.first
        guard let device else {
            NSLog("PianoCam audio: no audio input device found")
            state = .failed("No audio input device")
            return
        }
        NSLog("PianoCam audio: using device \(device.localizedName)")

        session.beginConfiguration()
        if let existing = audioInput {
            session.removeInput(existing)
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            NSLog("PianoCam audio: failed to create input for \(device.localizedName)")
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
                NSLog("PianoCam audio: cannot add audio output")
                state = .failed("Cannot add audio output")
                return
            }
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        tapCount = 0
        state = .running
        NSLog("PianoCam audio: capture started running=\(session.isRunning)")
    }
}

extension AudioPitchDetector: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        // Pull mono float samples out of the CMSampleBuffer's audio buffer list.
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

        let bytesPerSample = MemoryLayout<Float>.size
        let totalFrames = Int(buf.mDataByteSize) / bytesPerSample / Int(buf.mNumberChannels)
        let ptr = mData.assumingMemoryBound(to: Float.self)

        analysisQueue.async { [weak self] in
            self?.analyze(samples: ptr, frames: totalFrames, channels: Int(buf.mNumberChannels))
        }
    }

    private nonisolated func analyze(samples: UnsafePointer<Float>, frames: Int, channels: Int) {
        // For mono first-channel analysis, skip stride if interleaved.
        var rms: Float = 0
        if channels == 1 {
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frames))
        } else {
            // Take the first channel (interleaved).
            vDSP_rmsqv(samples, channels, &rms, vDSP_Length(frames))
        }

        let scaled = min(1.0, rms * 30)
        DispatchQueue.main.async { [weak self] in
            self?.inputLevel = scaled
            self?.tapCount += 1
            if let count = self?.tapCount, count <= 5 {
                NSLog("PianoCam audio: buffer #\(count) frames=\(frames) ch=\(channels) rms=\(String(format: "%.4f", rms))")
            }
        }

        let onsetThreshold: Float = 0.05
        let now = Date().timeIntervalSince1970
        if rms > onsetThreshold && now - lastOnsetTimeShared() > 0.18 {
            setLastOnsetTimeShared(now)
            DispatchQueue.main.async { [weak self] in
                self?.fireStubNote()
            }
        }
    }

    // Atomic scalar safe to access from the analysis queue without crossing actors.
    private nonisolated(unsafe) static let onsetLock = NSLock()
    private nonisolated(unsafe) static var sharedLastOnset: TimeInterval = 0
    private nonisolated func lastOnsetTimeShared() -> TimeInterval {
        Self.onsetLock.lock(); defer { Self.onsetLock.unlock() }
        return Self.sharedLastOnset
    }
    private nonisolated func setLastOnsetTimeShared(_ t: TimeInterval) {
        Self.onsetLock.lock(); Self.sharedLastOnset = t; Self.onsetLock.unlock()
    }

    private func fireStubNote() {
        let note: UInt8 = 60
        if activeStubNotes.contains(note) {
            onEvent?(.noteOff(note: note))
            activeStubNotes.remove(note)
        }
        let velocity = UInt8(min(127, max(40, Int(inputLevel * 200))))
        onEvent?(.noteOn(note: note, velocity: velocity))
        activeStubNotes.insert(note)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.activeStubNotes.remove(note) != nil {
                self.onEvent?(.noteOff(note: note))
            }
        }
    }
}
