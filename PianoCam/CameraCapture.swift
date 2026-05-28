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
    private var preferredZoomFactor: CGFloat?

    /// Called on the capture queue with the latest frame.
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// Real (non-virtual) cameras available on this Mac.
    static var availableDevices: [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                         mediaType: .video,
                                                         position: .unspecified)
        return discovery.devices.filter { $0.localizedName != cameraName }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.queue.async { self.configure(device: nil) }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// Applies a requested zoom to the current and future capture device.
    /// Values below the device minimum become the device's widest available
    /// zoom, so passing 0.5 requests ultra-wide when Continuity Camera exposes it.
    func setPreferredZoomFactor(_ factor: CGFloat?) {
        queue.async {
            self.preferredZoomFactor = factor
            if let device = self.input?.device {
                self.applyPreferredZoom(to: device)
            }
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
        applyPreferredZoom(to: device)
        if !session.isRunning { session.startRunning() }
    }

    private func applyPreferredZoom(to device: AVCaptureDevice) {
        guard let preferredZoomFactor else { return }
        let minSelector = NSSelectorFromString("minAvailableVideoZoomFactor")
        let maxSelector = NSSelectorFromString("maxAvailableVideoZoomFactor")
        let setterSelector = NSSelectorFromString("setVideoZoomFactor:")
        guard device.responds(to: minSelector),
              device.responds(to: maxSelector),
              device.responds(to: setterSelector),
              let minNumber = device.value(forKey: "minAvailableVideoZoomFactor") as? NSNumber,
              let maxNumber = device.value(forKey: "maxAvailableVideoZoomFactor") as? NSNumber else {
            NSLog("PianoCam: camera zoom is not exposed for \(device.localizedName)")
            return
        }

        do {
            try device.lockForConfiguration()
            let minimum = CGFloat(truncating: minNumber)
            let maximum = CGFloat(truncating: maxNumber)
            let zoom = min(max(preferredZoomFactor, minimum), maximum)
            device.setValue(NSNumber(value: Double(zoom)), forKey: "videoZoomFactor")
            device.unlockForConfiguration()
        } catch {
            NSLog("PianoCam: failed to set camera zoom for \(device.localizedName): \(error.localizedDescription)")
        }
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
