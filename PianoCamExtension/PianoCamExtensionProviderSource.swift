import Foundation
import CoreMediaIO

final class PianoCamExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: PianoCamExtensionDevice!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = PianoCamExtensionDevice(localizedName: "PianoCam")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            NSLog("PianoCamExtension: failed to add device: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerName, .providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) {
            props.name = "PianoCam"
        }
        if properties.contains(.providerManufacturer) {
            props.manufacturer = "PianoCam"
        }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}
}
