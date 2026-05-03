import Foundation

@MainActor
final class ExtensionInstaller: NSObject, ObservableObject {
    enum Status: Equatable {
        case active

        var description: String {
            return "Active — virtual camera is available to other apps"
        }
    }

    @Published private(set) var status: Status = .active
}
