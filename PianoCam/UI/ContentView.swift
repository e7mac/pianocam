import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var camera: CameraSession
    @EnvironmentObject var midi: MIDIInput
    @EnvironmentObject var piano: PianoState

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black
                cameraLayer
                    .frame(width: geo.size.width, height: geo.size.height)

                PianoKeyboardView(activeVelocities: piano.activeVelocities)
                    .frame(width: geo.size.width, height: geo.size.height * 0.25)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    @ViewBuilder
    private var cameraLayer: some View {
        switch camera.authorizationStatus {
        case .authorized:
            CameraPreviewView(session: camera.session)
        case .notDetermined:
            statusText("Requesting camera access…")
        case .denied, .restricted:
            statusText("Camera access denied. Enable PianoCam in System Settings → Privacy & Security → Camera.")
        @unknown default:
            statusText("Camera unavailable.")
        }
    }

    @ViewBuilder
    private func statusText(_ s: String) -> some View {
        Text(s)
            .font(.title3)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()
    }
}
