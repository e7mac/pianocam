#!/usr/bin/env swift
// Sends a C major scale + sustain pedal to "IAC Driver Bus 1".
// Run: swift tools/midi-test-sender.swift
import CoreMIDI
import Foundation

let destinationName = "IAC Driver Bus 1"

var client: MIDIClientRef = 0
MIDIClientCreateWithBlock("PianoCamTester" as CFString, &client, nil)
var port: MIDIPortRef = 0
MIDIOutputPortCreate(client, "out" as CFString, &port)

func findDestination(_ name: String) -> MIDIEndpointRef? {
    for i in 0..<MIDIGetNumberOfDestinations() {
        let ep = MIDIGetDestination(i)
        var nameRef: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &nameRef)
        if let n = nameRef?.takeRetainedValue() as String?, n == name {
            return ep
        }
    }
    return nil
}

guard let dest = findDestination(destinationName) else {
    print("No destination named '\(destinationName)'. Open Audio MIDI Setup → MIDI Studio → IAC Driver and check 'Device is online'.")
    exit(1)
}

func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    var bytes: [UInt8] = [status, d1, d2]
    _ = MIDIPacketListAdd(&packetList, 1024, packet, 0, 3, &bytes)
    MIDISend(port, dest, &packetList)
}

print("Sending C major scale + sustain to \(destinationName)…")
let scale: [UInt8] = [60, 62, 64, 65, 67, 69, 71, 72]
send(0xB0, 64, 127) // sustain on
for note in scale {
    send(0x90, note, 100) // note on
    Thread.sleep(forTimeInterval: 0.25)
}
Thread.sleep(forTimeInterval: 0.5)
send(0xB0, 64, 0) // sustain off
for note in scale {
    send(0x80, note, 0) // note off
    Thread.sleep(forTimeInterval: 0.01)
}
send(0xB0, 123, 0) // all notes off
Thread.sleep(forTimeInterval: 0.5) // let CoreMIDI flush before exit
print("Done.")
