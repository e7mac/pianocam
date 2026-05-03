//
//  PianoState.swift
//  samplecamera
//
//  Tracks which MIDI notes are currently held / sustained, with velocity.
//  Thread-safe so the capture-side render can read it from any queue.
//

import Foundation

enum MIDIEvent {
    case noteOn(note: UInt8, velocity: UInt8)
    case noteOff(note: UInt8)
    case sustain(down: Bool)
    case allNotesOff
}

final class PianoState {
    private let lock = NSLock()
    private var activeVelocitiesUnsafe: [UInt8: UInt8] = [:]
    private var heldNotes: Set<UInt8> = []
    private var sustainedNotes: [UInt8: UInt8] = [:]
    private var sustainDown: Bool = false

    var activeVelocities: [UInt8: UInt8] {
        lock.lock(); defer { lock.unlock() }
        return activeVelocitiesUnsafe
    }

    var isSustainDown: Bool {
        lock.lock(); defer { lock.unlock() }
        return sustainDown
    }

    func handle(_ event: MIDIEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .noteOn(let note, let velocity):
            guard (21...108).contains(note) else { return }
            if velocity == 0 {
                handleOffLocked(note: note)
                return
            }
            heldNotes.insert(note)
            sustainedNotes.removeValue(forKey: note)
            activeVelocitiesUnsafe[note] = velocity

        case .noteOff(let note):
            handleOffLocked(note: note)

        case .sustain(let down):
            sustainDown = down
            if !down {
                for note in sustainedNotes.keys where !heldNotes.contains(note) {
                    activeVelocitiesUnsafe.removeValue(forKey: note)
                }
                sustainedNotes.removeAll()
            }

        case .allNotesOff:
            heldNotes.removeAll()
            sustainedNotes.removeAll()
            activeVelocitiesUnsafe.removeAll()
        }
    }

    private func handleOffLocked(note: UInt8) {
        guard (21...108).contains(note) else { return }
        heldNotes.remove(note)
        if sustainDown {
            if let v = activeVelocitiesUnsafe[note] {
                sustainedNotes[note] = v
            }
        } else {
            activeVelocitiesUnsafe.removeValue(forKey: note)
        }
    }
}
