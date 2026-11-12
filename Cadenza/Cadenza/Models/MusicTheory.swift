import Foundation

/// A pitch together with the way it is written, so the staff can place it on the
/// right line and draw the right accidental (F♯ and G♭ sound the same but are drawn differently).
struct SpelledPitch: Equatable {
    /// MIDI note number (60 = middle C).
    let midi: Int
    /// Diatonic position: octave * 7 + letter index (C = 0 … B = 6). Middle C = 28.
    let staffStep: Int
    /// -1 flat, 0 natural, +1 sharp (doubles allowed).
    let accidental: Int
}

enum MusicTheory {
    static let letters: [Character] = ["C", "D", "E", "F", "G", "A", "B"]
    static let letterSemitones = [0, 2, 4, 5, 7, 9, 11]
    static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func isBlack(_ midi: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(((midi % 12) + 12) % 12)
    }

    static func frequency(of midi: Int) -> Double {
        440.0 * pow(2.0, Double(midi - 69) / 12.0)
    }

    static func octave(of midi: Int) -> Int {
        Int(floor(Double(midi) / 12.0)) - 1
    }

    /// "C♯4", "A0", …
    static func name(of midi: Int) -> String {
        sharpNames[((midi % 12) + 12) % 12] + String(octave(of: midi))
    }

    /// Letter name of a written note, e.g. "F♯".
    static func letterName(staffStep: Int, accidental: Int) -> String {
        let letter = String(letters[((staffStep % 7) + 7) % 7])
        switch accidental {
        case 1: return letter + "♯"
        case -1: return letter + "♭"
        case 2: return letter + "𝄪"
        case -2: return letter + "𝄫"
        default: return letter
        }
    }

    /// Parses scientific pitch notation such as "C4", "F#5", "Bb3".
    static func parse<S: StringProtocol>(_ token: S) -> SpelledPitch? {
        guard let first = token.first,
              let letterIndex = letters.firstIndex(of: Character(first.uppercased())) else { return nil }
        var rest = token.dropFirst()
        var accidental = 0
        while let c = rest.first, c == "#" || c == "b" {
            accidental += (c == "#") ? 1 : -1
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty, let octave = Int(String(rest)) else { return nil }
        let midi = (octave + 1) * 12 + letterSemitones[letterIndex] + accidental
        guard (0...127).contains(midi) else { return nil }
        return SpelledPitch(midi: midi, staffStep: octave * 7 + letterIndex, accidental: accidental)
    }
}
