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

    @Published var audioEnabled: Bool = false
    @Published var audioLevel: Float = 0
    @Published var audioStatus: String = "Off"

    @Published var audioInputs: [AVCaptureDevice] = []
    @Published var selectedAudioInputID: String?
    @Published var audioMode: AudioPitchMode = .basicPitch

    // Basic Pitch tunables, exposed in the UI.
    @Published var bpOnsetThreshold: Float = 0.30
    @Published var bpFrameThreshold: Float = 0.18
    @Published var bpSustainedFraction: Float = 0.20
    @Published var bpMinHoldSeconds: Double = 0.4
    @Published var speechRejectionEnabled: Bool = false
    /// Run a vocal-isolation model over the source audio before pitch
    /// transcription. ML-based, ~30s/min on Apple Silicon. Offline only.
    @Published var vocalIsolationEnabled: Bool = false

    /// Video processing UI state, mirrored from VideoProcessor.
    @Published var videoProcessing: Bool = false
    @Published var videoProcessingPhase: String = ""
    @Published var videoProcessingProgress: Double = 0
    @Published var videoProcessingError: String?
    @Published var videoProcessingOutput: URL?

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
    var audioToggled: (Bool) -> Void
    var audioInputSelected: (AVCaptureDevice) -> Void
    var audioModeChanged: (AudioPitchMode) -> Void
    var processVideo: () -> Void
    var revealOutput: () -> Void
}
