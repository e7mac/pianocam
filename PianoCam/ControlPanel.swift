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
            Divider()
            controlsRow
            Divider()
            PreviewLayerView(layer: previewLayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let host = CALayer()
        host.backgroundColor = NSColor.black.cgColor
        v.layer = host
        layer.videoGravity = .resizeAspect
        host.addSublayer(layer)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        layer.frame = nsView.bounds
    }
}
