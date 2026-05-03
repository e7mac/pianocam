import Foundation
import SystemExtensions

@MainActor
final class ExtensionInstaller: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case installing
        case requiresApproval
        case installed
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "Not installed"
            case .installing: return "Installing…"
            case .requiresApproval: return "Approve in System Settings → Privacy & Security"
            case .installed: return "Installed"
            case .failed(let msg): return "Failed: \(msg)"
            }
        }
    }

    @Published private(set) var status: Status = .idle

    func install() {
        guard let id = Self.embeddedExtensionIdentifier() else {
            status = .failed("Extension bundle not found inside app")
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: id,
            queue: .main
        )
        request.delegate = self
        status = .installing
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        guard let id = Self.embeddedExtensionIdentifier() else {
            status = .failed("Extension bundle not found inside app")
            return
        }
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: id,
            queue: .main
        )
        request.delegate = self
        status = .installing
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Reads the extension's CFBundleIdentifier from the embedded
    /// `Contents/Library/SystemExtensions/*.systemextension` so the
    /// activation request matches the real bundle layout.
    private static func embeddedExtensionIdentifier() -> String? {
        let dir = URL(fileURLWithPath: "Contents/Library/SystemExtensions",
                      relativeTo: Bundle.main.bundleURL)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ), let url = urls.first(where: { $0.pathExtension == "systemextension" }),
              let bundle = Bundle(url: url) else { return nil }
        return bundle.bundleIdentifier
    }
}

extension ExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.status = .requiresApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.status = .installed
            case .willCompleteAfterReboot:
                self.status = .requiresApproval
            @unknown default:
                self.status = .installed
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = (error as NSError).localizedDescription
        Task { @MainActor in self.status = .failed(message) }
    }
}
