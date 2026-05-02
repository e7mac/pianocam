import Foundation
import CoreMediaIO

final class PianoCamExtensionDevice: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: PianoCamExtensionStream!

    init(localizedName: String) {
        super.init()
        let deviceID = UUID(uuidString: "C4F7B8D2-4A3E-4F1A-9E27-8B6D9F2A7E11")!
        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceID,
            legacyDeviceID: nil,
            source: self
        )
        streamSource = PianoCamExtensionStream(
            localizedName: "PianoCam Stream",
            streamID: UUID(uuidString: "C4F7B8D2-4A3E-4F1A-9E27-8B6D9F2A7E12")!,
            device: device
        )
        do {
            try device.addStream(streamSource.stream)
        } catch {
            NSLog("PianoCamExtension: failed to add stream: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = 0x76697274 // 'virt' — virtual transport
        }
        if properties.contains(.deviceModel) {
            props.model = "PianoCam Virtual Camera"
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}
