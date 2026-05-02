import Foundation
import CoreMediaIO

let providerSource = PianoCamExtensionProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
