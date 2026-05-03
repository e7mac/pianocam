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

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high

        let device: AVCaptureDevice? = {
            // Prefer the built-in / external real camera, NOT our virtual one.
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
                mediaType: .video,
                position: .unspecified
            )
            return discovery.devices.first { d in
                d.localizedName != "Sample Camera"
            }
        }()
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }
        if session.canAddInput(input) {
            session.addInput(input)
            self.input = input
        }
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
        session.startRunning()
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
