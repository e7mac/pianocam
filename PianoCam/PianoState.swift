//
//  PianoState.swift
//  samplecamera
//
//  Tracks which MIDI notes are currently held / sustained, with velocity.
//  Thread-safe so the capture-side render can read it from any queue.
//

import Foundation

enum Pedal {
    case soft        // CC67 — una corda (left)
    case sostenuto   // CC66 — middle
    case sustain     // CC64 — damper (right)
}

enum MIDIEvent {
    case noteOn(note: UInt8, velocity: UInt8)
    case noteOff(note: UInt8)
    case pedal(Pedal, down: Bool)
    case allNotesOff
}

final class PianoState {
    private let lock = NSLock()
    private var activeVelocitiesUnsafe: [UInt8: UInt8] = [:]
    /// Wall-clock (or event-clock) time each note was most-recently triggered.
    /// Used by `renderedVelocities(at:)` to fade highlights with the natural
    /// piano decay curve, so visually-stuck notes (where the model never
    /// emits note-off) become invisible regardless of model behavior.
    private var noteOnTimesUnsafe: [UInt8: TimeInterval] = [:]
    private var heldNotes: Set<UInt8> = []
    private var sustainedNotes: [UInt8: UInt8] = [:]
    private var sustainDown: Bool = false
    private var sostenutoDown: Bool = false
    private var softDown: Bool = false

    /// Visual decay time-constant. Higher = slower fade. With τ = 1.5 s the
    /// rendered velocity halves every ~1 s — close to a real piano's natural
    /// loudness envelope.
    static let visualDecayTau: TimeInterval = 1.5
    /// Below this fraction of the original velocity, drop the note from
    /// `renderedVelocities` entirely so stuck notes go fully invisible.
    static let visualVisibilityFloor: Float = 0.05

    var activeVelocities: [UInt8: UInt8] {
        lock.lock(); defer { lock.unlock() }
        return activeVelocitiesUnsafe
    }

    var pedalsState: (soft: Bool, sostenuto: Bool, sustain: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (softDown, sostenutoDown, sustainDown)
    }

    var isSustainDown: Bool {
        lock.lock(); defer { lock.unlock() }
        return sustainDown
    }

    /// Velocities scaled by an exponential decay since onset, so the
    /// keyboard-overlay highlight visibly dims as the note rings out.
    /// `time` should be the same reference used when calling `handle(_:at:)`.
    /// Notes whose decayed velocity falls below `visualVisibilityFloor *
    /// originalVelocity` are dropped.
    func renderedVelocities(at time: TimeInterval) -> [UInt8: UInt8] {
        lock.lock(); defer { lock.unlock() }
        var out: [UInt8: UInt8] = [:]
        out.reserveCapacity(activeVelocitiesUnsafe.count)
        for (note, vel) in activeVelocitiesUnsafe {
            let onAt = noteOnTimesUnsafe[note] ?? time
            let dt = max(0, time - onAt)
            let factor = exp(-dt / Self.visualDecayTau)
            if factor < Double(Self.visualVisibilityFloor) { continue }
            out[note] = UInt8(min(127, Int((Double(vel) * factor).rounded())))
        }
        return out
    }

    /// Apply a MIDI event. `time` is the event's wall-clock or scheduled
    /// time and is used by `renderedVelocities(at:)` for decay. Defaults to
    /// "now" — pass an explicit timestamp from the offline pipeline so the
    /// decay tracks audio-time, not host-time.
    func handle(_ event: MIDIEvent, at time: TimeInterval = Date().timeIntervalSince1970) {
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
            noteOnTimesUnsafe[note] = time

        case .noteOff(let note):
            handleOffLocked(note: note)

        case .pedal(.sustain, let down):
            sustainDown = down
            if !down {
                for note in sustainedNotes.keys where !heldNotes.contains(note) {
                    activeVelocitiesUnsafe.removeValue(forKey: note)
                    noteOnTimesUnsafe.removeValue(forKey: note)
                }
                sustainedNotes.removeAll()
            }

        case .pedal(.sostenuto, let down):
            sostenutoDown = down

        case .pedal(.soft, let down):
            softDown = down

        case .allNotesOff:
            heldNotes.removeAll()
            sustainedNotes.removeAll()
            activeVelocitiesUnsafe.removeAll()
            noteOnTimesUnsafe.removeAll()
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
            noteOnTimesUnsafe.removeValue(forKey: note)
        }
    }
}
