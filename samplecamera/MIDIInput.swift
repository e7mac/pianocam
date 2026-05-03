//
//  MIDIInput.swift
//  samplecamera
//
//  Connects to all available CoreMIDI sources and forwards parsed
//  note-on / note-off / sustain events to a callback.
//

import CoreMIDI
import Foundation

final class MIDIInput {
    /// Called on a background CoreMIDI thread.
    var onEvent: ((MIDIEvent) -> Void)?

    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var connected: Set<MIDIEndpointRef> = []

    func start() {
        guard client == 0 else { return refreshConnections() }

        let status = MIDIClientCreateWithBlock("samplecamera" as CFString, &client) { [weak self] notif in
            switch notif.pointee.messageID {
            case .msgObjectAdded, .msgObjectRemoved, .msgSetupChanged:
                DispatchQueue.main.async { self?.refreshConnections() }
            default: break
            }
        }
        guard status == noErr else { return }

        MIDIInputPortCreateWithProtocol(client, "samplecamera.in" as CFString, ._1_0, &port) { [weak self] eventList, _ in
            guard let self else { return }
            let list = eventList.pointee
            var packet = list.packet
            for _ in 0..<list.numPackets {
                let words = withUnsafeBytes(of: packet.words) { ptr -> [UInt32] in
                    let buf = ptr.bindMemory(to: UInt32.self)
                    return Array(buf.prefix(Int(packet.wordCount)))
                }
                Self.parse(words: words) { event in self.onEvent?(event) }
                packet = MIDIEventPacketNext(&packet).pointee
            }
        }

        refreshConnections()
    }

    func refreshConnections() {
        guard port != 0 else { return }
        let count = MIDIGetNumberOfSources()
        var seen: Set<MIDIEndpointRef> = []
        for i in 0..<count {
            let ep = MIDIGetSource(i)
            guard ep != 0 else { continue }
            seen.insert(ep)
            if !connected.contains(ep) {
                if MIDIPortConnectSource(port, ep, nil) == noErr {
                    connected.insert(ep)
                }
            }
        }
        // Drop endpoints that disappeared.
        let stale = connected.subtracting(seen)
        for ep in stale {
            MIDIPortDisconnectSource(port, ep)
            connected.remove(ep)
        }
    }

    private static func parse(words: [UInt32], emit: (MIDIEvent) -> Void) {
        guard let first = words.first else { return }
        let messageType = (first >> 28) & 0xF
        switch messageType {
        case 0x2: // legacy MIDI 1.0 in UMP
            let status = UInt8((first >> 16) & 0xFF)
            let d1 = UInt8((first >> 8) & 0x7F)
            let d2 = UInt8(first & 0x7F)
            handleStatus(status: status, d1: d1, d2: d2, emit: emit)
        case 0x4: // MIDI 2.0 channel voice
            guard words.count >= 2 else { return }
            let status = UInt8((first >> 16) & 0xFF)
            let opcode = status & 0xF0
            let note = UInt8((first >> 8) & 0x7F)
            let velocity16 = UInt16(words[1] >> 16)
            let vel7 = UInt8(min(127, Int(velocity16) >> 9))
            switch opcode {
            case 0x90: emit(vel7 == 0 ? .noteOff(note: note) : .noteOn(note: note, velocity: vel7))
            case 0x80: emit(.noteOff(note: note))
            case 0xB0:
                let cc = note
                let value7 = UInt8(min(127, Int(words[1] >> 25)))
                if cc == 64 { emit(.sustain(down: value7 >= 64)) }
                if cc == 123 { emit(.allNotesOff) }
            default: break
            }
        default: break
        }
    }

    private static func handleStatus(status: UInt8, d1: UInt8, d2: UInt8, emit: (MIDIEvent) -> Void) {
        let opcode = status & 0xF0
        switch opcode {
        case 0x90: emit(d2 == 0 ? .noteOff(note: d1) : .noteOn(note: d1, velocity: d2))
        case 0x80: emit(.noteOff(note: d1))
        case 0xB0:
            if d1 == 64 { emit(.sustain(down: d2 >= 64)) }
            if d1 == 123 { emit(.allNotesOff) }
        default: break
        }
    }
}
