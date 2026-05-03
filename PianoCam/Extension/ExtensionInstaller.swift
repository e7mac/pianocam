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

    static let extensionBundleIdentifier = "com.mayank.pianocam.extension"

    func install() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        status = .installing
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        status = .installing
        OSSystemExtensionManager.shared.submitRequest(request)
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
