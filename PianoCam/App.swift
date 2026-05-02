import SwiftUI

@main
struct PianoCamApp: App {
    @StateObject private var camera = CameraSession()
    @StateObject private var midi = MIDIInput()
    @StateObject private var piano = PianoState()
    @StateObject private var installer = ExtensionInstaller()
    @StateObject private var composited = CompositedFrameSource()

    var body: some Scene {
        Window("PianoCam", id: "main") {
            ContentView()
                .environmentObject(camera)
                .environmentObject(midi)
                .environmentObject(piano)
                .environmentObject(installer)
                .frame(minWidth: 640, minHeight: 480)
                .onAppear {
                    midi.onEvent = { [weak piano] event in
                        piano?.handle(event)
                    }
                    composited.bind(camera: camera, piano: piano)
                    camera.start()
                    midi.start()
                }
        }
        .windowResizability(.contentSize)

        Window("Composited Output (1080p)", id: "composited") {
            CompositedPreviewView(source: composited)
                .frame(minWidth: 640, minHeight: 360)
                .background(Color.black)
        }
        .defaultSize(width: 960, height: 540)

        Settings {
            SettingsView()
                .environmentObject(camera)
                .environmentObject(midi)
                .environmentObject(installer)
        }
    }
}
