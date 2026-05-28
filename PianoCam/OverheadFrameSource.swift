//
//  OverheadFrameSource.swift
//  PianoCam
//
//  Common interface for objects that produce overhead-camera frames.
//  Conformed to by `CameraCapture` (live AVCaptureSession) and
//  `SimulatedOverheadSource` (disk-backed dev tool).
//

import AVFoundation
import CoreVideo

protocol OverheadFrameSource: AnyObject {
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    func start()
    func stop()
    func setDevice(_ device: AVCaptureDevice?)
    func setPreferredZoomFactor(_ factor: CGFloat?)
}
