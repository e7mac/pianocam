import AVFoundation
import Combine
import CoreVideo
import Foundation

@MainActor
final class CameraSession: NSObject, ObservableObject {
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published var selectedDeviceID: String? {
        didSet {
            guard oldValue != selectedDeviceID else { return }
            reconfigure()
        }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var authorizationStatus: AVAuthorizationStatus = .notDetermined

    nonisolated let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pianocam.camera.session")
    /// Accessed only on `queue`.
    nonisolated(unsafe) private var currentInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var videoOutput: AVCaptureVideoDataOutput?

    /// Called on `queue` for every captured frame.
    nonisolated(unsafe) var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    override init() {
        super.init()
        session.sessionPreset = .high
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        refreshDevices()
    }

    func start() {
        switch authorizationStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.authorizationStatus = granted ? .authorized : .denied
                    if granted {
                        self.refreshDevices()
                        self.reconfigure()
                    }
                }
            }
        case .authorized:
            refreshDevices()
            reconfigure()
        default:
            break
        }
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .deskViewCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        devices = discovery.devices
        if selectedDeviceID == nil {
            selectedDeviceID = AVCaptureDevice.default(for: .video)?.uniqueID ?? devices.first?.uniqueID
        }
    }

    private func reconfigure() {
        guard authorizationStatus == .authorized else { return }
        let deviceID = selectedDeviceID
        let session = self.session
        queue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()

            if let existing = self.currentInput {
                session.removeInput(existing)
                self.currentInput = nil
            }

            let device: AVCaptureDevice? = {
                if let id = deviceID { return AVCaptureDevice(uniqueID: id) }
                return AVCaptureDevice.default(for: .video)
            }()
            if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                self.currentInput = input
            }

            if self.videoOutput == nil {
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.queue)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    self.videoOutput = output
                }
            }

            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }

            let running = session.isRunning
            Task { @MainActor in self.isRunning = running }
        }
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pb, pts)
    }
}
