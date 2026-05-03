import SwiftUI
import CoreMIDI

struct SettingsView: View {
    @EnvironmentObject var camera: CameraSession
    @EnvironmentObject var midi: MIDIInput
    @EnvironmentObject var installer: ExtensionInstaller

    var body: some View {
        Form {
            cameraSection
            midiSection
            extensionSection
        }
        .padding(20)
        .frame(width: 460)
    }

    private var extensionSection: some View {
        Section("Virtual Camera") {
            HStack {
                Text("Status")
                Spacer()
                Text(installer.status.description)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cameraSection: some View {
        Section("Camera") {
            Picker("Webcam", selection: cameraBinding) {
                ForEach(camera.devices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
                if camera.devices.isEmpty {
                    Text("No cameras found").tag("")
                }
            }
            Button("Refresh") { camera.refreshDevices() }
        }
    }

    private var midiSection: some View {
        Section("MIDI Input") {
            Picker("Source", selection: midiBinding) {
                ForEach(midi.sources) { src in
                    Text(src.name).tag(src.id)
                }
                if midi.sources.isEmpty {
                    Text("No MIDI sources").tag(MIDIUniqueID(0))
                }
            }
            Button("Refresh") { midi.refreshSources() }
        }
    }

    private var cameraBinding: Binding<String> {
        Binding(
            get: { camera.selectedDeviceID ?? "" },
            set: { camera.selectedDeviceID = $0.isEmpty ? nil : $0 }
        )
    }

    private var midiBinding: Binding<MIDIUniqueID> {
        Binding(
            get: { midi.selectedSourceID ?? 0 },
            set: { midi.selectedSourceID = $0 == 0 ? nil : $0 }
        )
    }
}
