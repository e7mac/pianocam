import CoreMIDI
import Combine
import Foundation

struct MIDISource: Identifiable, Hashable {
    let id: MIDIUniqueID
    let name: String
    let endpoint: MIDIEndpointRef
}

@MainActor
final class MIDIInput: ObservableObject {
    @Published private(set) var sources: [MIDISource] = []
    @Published var selectedSourceID: MIDIUniqueID? {
        didSet {
            guard oldValue != selectedSourceID else { return }
            reconnect()
        }
    }

    /// Called on the main actor for every parsed MIDI event.
    var onEvent: ((MIDIEvent) -> Void)?

    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var connectedEndpoint: MIDIEndpointRef = 0

    func start() {
        guard client == 0 else {
            refreshSources()
            return
        }
        let name = "PianoCam" as CFString
        let status = MIDIClientCreateWithBlock(name, &client) { [weak self] notificationPtr in
            let notif = notificationPtr.pointee
            switch notif.messageID {
            case .msgObjectAdded, .msgObjectRemoved, .msgSetupChanged:
                Task { @MainActor in self?.refreshSources() }
            default:
                break
            }
        }
        guard status == noErr else { return }

        let portStatus = MIDIInputPortCreateWithProtocol(
            client,
            "PianoCam.in" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventList, _ in
            let list = eventList.pointee
            var packet = list.packet
            for _ in 0..<list.numPackets {
                let words = withUnsafeBytes(of: packet.words) { ptr -> [UInt32] in
                    let buf = ptr.bindMemory(to: UInt32.self)
                    return Array(buf.prefix(Int(packet.wordCount)))
                }
                Self.parse(words: words) { event in
                    Task { @MainActor in self?.onEvent?(event) }
                }
                packet = MIDIEventPacketNext(&packet).pointee
            }
        }
        guard portStatus == noErr else { return }

        refreshSources()
    }

    func refreshSources() {
        let count = MIDIGetNumberOfSources()
        var newSources: [MIDISource] = []
        for i in 0..<count {
            let endpoint = MIDIGetSource(i)
            guard endpoint != 0 else { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
            var nameRef: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &nameRef)
            let name = nameRef?.takeRetainedValue() as String? ?? "Source \(i)"
            newSources.append(MIDISource(id: uid, name: name, endpoint: endpoint))
        }
        sources = newSources

        if let id = selectedSourceID, !newSources.contains(where: { $0.id == id }) {
            selectedSourceID = newSources.first?.id
        } else if selectedSourceID == nil {
            selectedSourceID = newSources.first?.id
        } else {
            // re-bind in case endpoint ref changed
            reconnect()
        }
    }

    private func reconnect() {
        guard inputPort != 0 else { return }
        if connectedEndpoint != 0 {
            MIDIPortDisconnectSource(inputPort, connectedEndpoint)
            connectedEndpoint = 0
        }
        guard let id = selectedSourceID,
              let src = sources.first(where: { $0.id == id }) else { return }
        let status = MIDIPortConnectSource(inputPort, src.endpoint, nil)
        if status == noErr {
            connectedEndpoint = src.endpoint
        }
    }

    // MARK: - Parsing

    private static func parse(words: [UInt32], emit: (MIDIEvent) -> Void) {
        guard let first = words.first else { return }
        let messageType = (first >> 28) & 0xF
        switch messageType {
        case 0x2: // MIDI 1.0 channel voice in UMP
            let status = UInt8((first >> 16) & 0xFF)
            let data1 = UInt8((first >> 8) & 0x7F)
            let data2 = UInt8(first & 0x7F)
            handleStatus(status: status, data1: data1, data2: data2, emit: emit)
        case 0x4: // MIDI 2.0 channel voice
            guard words.count >= 2 else { return }
            let status = UInt8((first >> 16) & 0xFF)
            let opcode = status & 0xF0
            let note = UInt8((first >> 8) & 0x7F)
            let velocity16 = UInt16(words[1] >> 16)
            let vel7 = UInt8(min(127, Int(velocity16) >> 9))
            switch opcode {
            case 0x90:
                emit(vel7 == 0 ? .noteOff(note: note) : .noteOn(note: note, velocity: vel7))
            case 0x80:
                emit(.noteOff(note: note))
            case 0xB0:
                let cc = note
                let value7 = UInt8(min(127, Int(words[1] >> 25)))
                if cc == 64 { emit(.sustain(down: value7 >= 64)) }
                if cc == 123 { emit(.allNotesOff) }
            default: break
            }
        default:
            break
        }
    }

    private static func handleStatus(status: UInt8, data1: UInt8, data2: UInt8, emit: (MIDIEvent) -> Void) {
        let opcode = status & 0xF0
        switch opcode {
        case 0x90:
            emit(data2 == 0 ? .noteOff(note: data1) : .noteOn(note: data1, velocity: data2))
        case 0x80:
            emit(.noteOff(note: data1))
        case 0xB0:
            if data1 == 64 { emit(.sustain(down: data2 >= 64)) }
            if data1 == 123 { emit(.allNotesOff) }
        default:
            break
        }
    }
}
