import Foundation
import Combine

enum MIDIEvent {
    case noteOn(note: UInt8, velocity: UInt8)
    case noteOff(note: UInt8)
    case sustain(down: Bool)
    case allNotesOff
}

@MainActor
final class PianoState: ObservableObject {
    /// Active note → velocity (0-127). Includes sustained notes while pedal is down.
    @Published private(set) var activeVelocities: [UInt8: UInt8] = [:]
    @Published private(set) var sustainDown: Bool = false

    /// Notes physically held by the player (key still down).
    private var heldNotes: Set<UInt8> = []
    /// Notes whose physical key is up but are sustained by the pedal.
    private var sustainedNotes: [UInt8: UInt8] = [:]

    func handle(_ event: MIDIEvent) {
        switch event {
        case .noteOn(let note, let velocity):
            guard (21...108).contains(note) else { return }
            if velocity == 0 {
                handle(.noteOff(note: note))
                return
            }
            heldNotes.insert(note)
            sustainedNotes.removeValue(forKey: note)
            activeVelocities[note] = velocity

        case .noteOff(let note):
            guard (21...108).contains(note) else { return }
            heldNotes.remove(note)
            if sustainDown {
                if let v = activeVelocities[note] {
                    sustainedNotes[note] = v
                }
            } else {
                activeVelocities.removeValue(forKey: note)
            }

        case .sustain(let down):
            sustainDown = down
            if !down {
                for note in sustainedNotes.keys where !heldNotes.contains(note) {
                    activeVelocities.removeValue(forKey: note)
                }
                sustainedNotes.removeAll()
            }

        case .allNotesOff:
            heldNotes.removeAll()
            sustainedNotes.removeAll()
            activeVelocities.removeAll()
        }
    }
}
