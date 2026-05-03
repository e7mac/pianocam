//
//  HostState.swift
//  PianoCam
//
//  Observable state surface for the SwiftUI control panel. The view controller
//  owns one of these and pushes updates as CMIO / AV / MIDI events come in.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class HostState: ObservableObject {
    enum ExtensionStatus: String, Equatable {
        case unknown = "Unknown"
        case activating = "Activating…"
        case needsApproval = "Needs Approval"
        case active = "Active"
        case inactive = "Not installed"
        case failed = "Failed"
    }

    @Published var extensionStatus: ExtensionStatus = .unknown
    @Published var statusMessage: String = ""

    @Published var cameras: [AVCaptureDevice] = []
    @Published var selectedCameraID: String?

    @Published var midiSources: [String] = []

    @Published var sinkConnected: Bool = false
    @Published var streamingToConsumer: Bool = false

    @Published var mirrorCamera: Bool = false

    /// Append a line to the rolling debug log.
    func log(_ line: String) {
        statusMessage = line
        NSLog("PianoCam: \(line)")
    }
}

/// Side-effect callbacks the SwiftUI panel invokes.
struct HostActions {
    var activate: () -> Void
    var deactivate: () -> Void
    var reconnect: () -> Void
    var cameraSelected: (AVCaptureDevice) -> Void
}
