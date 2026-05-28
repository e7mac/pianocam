//
//  ControlPanel.swift
//  PianoCam
//
//  SwiftUI UI: status pill, control buttons, camera picker, MIDI status,
//  and the live composited preview hosted via AVSampleBufferDisplayLayer.
//

import AppKit
import AVFoundation
import SwiftUI

struct ControlPanel: View {
    @ObservedObject var state: HostState
    let actions: HostActions
    let previewLayer: AVSampleBufferDisplayLayer

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.videoProcessing || state.videoProcessingError != nil
                || state.videoProcessingOutput != nil {
                Divider()
                videoProcessingBar
            }
            Divider()
            controlsRow
            Divider()
            overheadControls
            if state.audioMode == .basicPitch {
                Divider()
                basicPitchSettings
            }
            Divider()
            PreviewLayerView(layer: previewLayer,
                             onMouseDown: state.calibrationStep > 0
                                ? { [actions] point, viewSize in
                                    actions.previewClick(point, viewSize)
                                  }
                                : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var videoProcessingBar: some View {
        HStack(spacing: 12) {
            if state.videoProcessing {
                ProgressView(value: state.videoProcessingProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                Text(state.videoProcessingPhase + " — " + String(format: "%.0f%%", state.videoProcessingProgress * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if let err = state.videoProcessingError {
                Text("Video processing failed: \(err)")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if state.videoProcessingOutput != nil {
                Text("Video saved.")
                    .font(.system(size: 11))
                Button("Reveal in Finder", action: actions.revealOutput)
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var basicPitchSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Basic Pitch settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                settingRow("Onset threshold",
                           value: $state.bpOnsetThreshold,
                           range: 0.10 ... 0.95,
                           help: "Probability needed for a strong note attack to register. Higher = fewer false positives, but quiet notes may be missed.")
                settingRow("Sustained note threshold",
                           value: $state.bpFrameThreshold,
                           range: 0.05 ... 0.80,
                           help: "Per-frame probability above which the note is considered still ringing.")
                settingRow("Sustained note fraction",
                           value: $state.bpSustainedFraction,
                           range: 0.05 ... 0.80,
                           help: "Fraction of recent frames the note must be active to keep the key lit.")
                settingRow("Minimum hold (sec)",
                           value: minHoldFloatBinding,
                           range: 0.0 ... 2.0,
                           help: "Each note stays lit for at least this long after detection, regardless of model output.")
                Toggle("Speech rejection (experimental)", isOn: $state.speechRejectionEnabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Mute speech-like audio chunks before pitch detection. Helps with talking-into-the-mic false positives but may dim quiet piano during overlap.")
                Toggle("Remove vocals (offline only, slow)", isOn: $state.vocalIsolationEnabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Run an ML vocal-isolation model on the source audio before pitch transcription. Big quality win on YouTube material with vocals/talking, but adds ~30s of processing per minute of audio.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func settingRow(_ title: String,
                            value: Binding<Float>,
                            range: ClosedRange<Float>,
                            help: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 11))
                .frame(width: 180, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
                .frame(maxWidth: 320)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .help(help)
    }

    private var minHoldFloatBinding: Binding<Float> {
        Binding(
            get: { Float(state.bpMinHoldSeconds) },
            set: { state.bpMinHoldSeconds = Double($0) }
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("PianoCam")
                .font(.system(size: 18, weight: .semibold))
            statusPill
            Spacer()
            Button("Activate", action: actions.activate)
                .disabled(state.extensionStatus == .activating ||
                          state.extensionStatus == .active)
            Button("Deactivate", action: actions.deactivate)
                .disabled(state.extensionStatus != .active)
            Button("Reconnect", action: actions.reconnect)
                .help("Re-link the host app to the camera extension's sink stream.")
            Button("Process Video…", action: actions.processVideo)
                .disabled(state.videoProcessing)
                .help("Pick a video file; PianoCam analyzes its audio and renders a new video with the piano overlay.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(state.extensionStatus.rawValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 99)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 99)
                .strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var statusColor: Color {
        switch state.extensionStatus {
        case .active: return .green
        case .activating: return .yellow
        case .needsApproval: return .orange
        case .failed: return .red
        case .inactive, .unknown: return .gray
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CAMERA")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: cameraBinding) {
                    if state.cameras.isEmpty {
                        Text("No cameras found").tag(String?.none)
                    }
                    ForEach(state.cameras, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(String?.some(d.uniqueID))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("MIDI")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(state.midiSources.isEmpty ? "No sources connected"
                                                : state.midiSources.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("AUDIO")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(state.audioStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(state.audioStatus.hasPrefix("Failed") ? .red : .secondary)
                }
                HStack(spacing: 8) {
                    Toggle("", isOn: audioBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    Picker("", selection: audioInputBinding) {
                        if state.audioInputs.isEmpty {
                            Text("No mic detected").tag(String?.none)
                        }
                        ForEach(state.audioInputs, id: \.uniqueID) { d in
                            Text(d.localizedName).tag(String?.some(d.uniqueID))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    Picker("", selection: audioModeBinding) {
                        ForEach(AudioPitchMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    AudioMeter(level: state.audioLevel)
                        .frame(width: 60, height: 8)
                }
            }

            Spacer()

            Toggle("Mirror", isOn: $state.mirrorCamera)
                .toggleStyle(.switch)
                .controlSize(.small)

            VStack(alignment: .trailing, spacing: 4) {
                badge("Sink", on: state.sinkConnected)
                badge("Streaming", on: state.streamingToConsumer)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var overheadControls: some View {
        HStack(spacing: 16) {
            Toggle("Overhead piano", isOn: overheadEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)

            if let simLabel = state.simulatedOverheadLabel {
                Text("Simulated — \(simLabel)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
            } else {
                Picker("", selection: overheadCameraBinding) {
                    if state.cameras.isEmpty {
                        Text("No cameras found").tag(String?.none)
                    }
                    ForEach(state.cameras, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(String?.some(d.uniqueID))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                .disabled(!state.overheadKeyboardEnabled)
            }

            Picker("Keys", selection: $state.overheadKeyCount) {
                ForEach([88, 76, 61, 49, 25], id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .frame(width: 100)
            .disabled(!state.overheadKeyboardEnabled)

            Stepper("Lowest MIDI \(state.overheadLowestMIDINote)",
                    value: $state.overheadLowestMIDINote,
                    in: 0...127)
                .frame(width: 160)
                .disabled(!state.overheadKeyboardEnabled)

            Toggle("Flip top/bottom", isOn: $state.overheadFlipVertical)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(!state.overheadKeyboardEnabled)

            Toggle("Lock", isOn: $state.overheadAlignmentLocked)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(!state.overheadKeyboardEnabled)
                .help("Freeze the current alignment. Detection stops running and the overlay stops drifting between fits.")

            if state.calibrationStep == 0 {
                Button("Calibrate") { actions.startCalibration() }
                    .controlSize(.small)
                    .disabled(!state.overheadKeyboardEnabled)
                    .help("Click the keyboard's four corners (top-left, top-right, bottom-right, bottom-left) to manually set the alignment.")
            } else {
                let labels = ["", "Click top-left", "Click top-right", "Click bottom-right", "Click bottom-left"]
                HStack(spacing: 6) {
                    Text(labels[state.calibrationStep])
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Button("Cancel") { actions.cancelCalibration() }
                        .controlSize(.small)
                }
            }

            Text(state.overheadAlignmentStatus)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(state.overheadAlignmentConfidence >= 0.55 ? .green : .secondary)
                .lineLimit(1)
                .frame(minWidth: 190, alignment: .leading)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func badge(_ title: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? .green : .gray.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var cameraBinding: Binding<String?> {
        Binding(
            get: { state.selectedCameraID },
            set: { newID in
                state.selectedCameraID = newID
                if let id = newID, let d = state.cameras.first(where: { $0.uniqueID == id }) {
                    actions.cameraSelected(d)
                }
            }
        )
    }

    private var overheadCameraBinding: Binding<String?> {
        Binding(
            get: { state.selectedOverheadCameraID },
            set: { newID in
                state.selectedOverheadCameraID = newID
                if let id = newID, let d = state.cameras.first(where: { $0.uniqueID == id }) {
                    actions.overheadCameraSelected(d)
                }
            }
        )
    }

    private var overheadEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.overheadKeyboardEnabled },
            set: { actions.overheadToggled($0) }
        )
    }

    private var audioBinding: Binding<Bool> {
        Binding(
            get: { state.audioEnabled },
            set: { actions.audioToggled($0) }
        )
    }

    private var audioInputBinding: Binding<String?> {
        Binding(
            get: { state.selectedAudioInputID },
            set: { newID in
                state.selectedAudioInputID = newID
                if let id = newID, let d = state.audioInputs.first(where: { $0.uniqueID == id }) {
                    actions.audioInputSelected(d)
                }
            }
        )
    }

    private var audioModeBinding: Binding<AudioPitchMode> {
        Binding(
            get: { state.audioMode },
            set: { actions.audioModeChanged($0) }
        )
    }
}

private struct AudioMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [.green, .yellow, .red],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(level))))
            }
        }
    }
}

private struct PreviewLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    /// Called with (clickPointTopLeftOrigin, viewBounds.size) when the
    /// user clicks. Used by the manual-calibration flow to capture the
    /// four keyboard-corner positions.
    var onMouseDown: ((CGPoint, CGSize) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = ClickCaptureView()
        v.wantsLayer = true
        let host = CALayer()
        host.backgroundColor = NSColor.black.cgColor
        v.layer = host
        layer.videoGravity = .resizeAspect
        host.addSublayer(layer)
        v.onMouseDown = onMouseDown
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        layer.frame = nsView.bounds
        (nsView as? ClickCaptureView)?.onMouseDown = onMouseDown
    }
}

/// Simple NSView that forwards mouseDown events with the point in view
/// coordinates (top-left origin) plus the current view size so the
/// caller can map into the composite's coordinate space.
private final class ClickCaptureView: NSView {
    var onMouseDown: ((CGPoint, CGSize) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let topLeft = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseDown?(topLeft, bounds.size)
    }
}
