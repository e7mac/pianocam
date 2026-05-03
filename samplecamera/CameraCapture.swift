//
//  CameraCapture.swift
//  samplecamera
//
//  Captures frames from the user's real webcam (NOT our virtual one) and
//  hands them off as `CVPixelBuffer`s for compositing.
//

import AVFoundation
import Foundation

final class CameraCapture: NSObject {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pianocam.cameracapture", qos: .userInteractive)
    private var input: AVCaptureDeviceInput?
    private var output = AVCaptureVideoDataOutput()

    /// Called on the capture queue with the latest frame.
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// Real (non-virtual) cameras available on this Mac.
    static var availableDevices: [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.filter { $0.localizedName != cameraName }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.queue.async { self.configure(device: nil) }
        }
    }

    /// Switch to a specific device. Pass nil to use the first available real camera.
    func setDevice(_ device: AVCaptureDevice?) {
        queue.async { self.configure(device: device) }
    }

    private func configure(device explicit: AVCaptureDevice?) {
        session.beginConfiguration()
        session.sessionPreset = .high

        if let existing = input {
            session.removeInput(existing)
            input = nil
        }

        let device = explicit ?? Self.availableDevices.first
        guard let device, let newInput = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            self.input = newInput
        }
        if !session.outputs.contains(output) {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb)
    }
}
