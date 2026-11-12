import Foundation

enum InputSource {
    case touch, midi, microphone
}

/// Anything that wants to hear the notes the player plays (normally the active practice session).
protocol NoteReceiver: AnyObject {
    func noteOn(_ pitch: Int, velocity: Int, source: InputSource)
    func noteOff(_ pitch: Int, source: InputSource)
}
