import Foundation

enum Hand: String, Codable, CaseIterable, Hashable {
    case left, right

    var title: String { self == .left ? "Left hand" : "Right hand" }
}

enum Level: String, Codable, CaseIterable, Identifiable, Comparable {
    case beginner, easy, intermediate, advanced

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var rank: Int { Level.allCases.firstIndex(of: self) ?? 0 }

    static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
}

/// One note in a song. Times are measured in beats from the start of the song.
struct NoteEvent: Identifiable, Hashable {
    let id: Int
    let pitch: Int
    let start: Double
    let duration: Double
    let hand: Hand
    /// Diatonic staff position (see `SpelledPitch.staffStep`).
    let staffStep: Int
    let accidental: Int

    var end: Double { start + duration }
}

struct Song: Identifiable {
    let id: String
    let title: String
    let composer: String
    let level: Level
    let genre: String
    /// Beats per minute, where one beat is a `beatUnit` note.
    let tempo: Double
    let beatsPerBar: Int
    /// 4 = a beat is a quarter note, 8 = a beat is an eighth note.
    let beatUnit: Int
    /// Length of an incomplete first bar (anacrusis), in beats; 0 when there is none.
    let pickup: Double
    let keyName: String
    /// Sorted by start time, then pitch.
    let notes: [NoteEvent]
    let totalBeats: Double
    /// Start beat of every bar. Bar 0 is the pickup bar when the song has one.
    let barStarts: [Double]

    init(id: String, title: String, composer: String, level: Level, genre: String,
         tempo: Double, beatsPerBar: Int, beatUnit: Int = 4, pickup: Double = 0,
         keyName: String, notes: [NoteEvent], totalBeats: Double) {
        self.id = id
        self.title = title
        self.composer = composer
        self.level = level
        self.genre = genre
        self.tempo = tempo
        self.beatsPerBar = max(1, beatsPerBar)
        self.beatUnit = beatUnit
        self.pickup = pickup
        self.keyName = keyName
        self.notes = notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        let length = max(totalBeats, notes.map(\.end).max() ?? 0)
        self.totalBeats = length

        var starts: [Double] = [0]
        var beat = pickup > 0 ? pickup : Double(self.beatsPerBar)
        while beat < length - 1e-6 {
            starts.append(beat)
            beat += Double(self.beatsPerBar)
        }
        self.barStarts = starts
    }

    var barCount: Int { barStarts.count }
    var timeSignature: String { "\(beatsPerBar)/\(beatUnit)" }
    var durationSeconds: Double { totalBeats / tempo * 60 }
    var hands: Set<Hand> { Set(notes.map(\.hand)) }

    var pitchRange: ClosedRange<Int> {
        let pitches = notes.map(\.pitch)
        return (pitches.min() ?? 60)...(pitches.max() ?? 72)
    }

    func barStart(_ bar: Int) -> Double {
        barStarts[min(max(bar, 0), barStarts.count - 1)]
    }

    func barEnd(_ bar: Int) -> Double {
        bar + 1 < barStarts.count ? barStarts[bar + 1] : totalBeats
    }

    func bar(at beat: Double) -> Int {
        barStarts.lastIndex { $0 <= beat + 1e-6 } ?? 0
    }

    /// Whether `beat` is a whole number of beats from the start of a bar (for the metronome).
    func isDownbeat(_ beat: Double) -> Bool {
        let offset = beat - (pickup > 0 ? pickup : 0)
        let r = offset.truncatingRemainder(dividingBy: Double(beatsPerBar))
        return abs(r) < 1e-6 || abs(abs(r) - Double(beatsPerBar)) < 1e-6
    }

    /// Displayed note length in quarter notes (independent of `beatUnit`).
    func quarterLength(of note: NoteEvent) -> Double {
        note.duration * 4.0 / Double(beatUnit)
    }

    func formattedDuration() -> String {
        let s = Int(durationSeconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Song: Hashable {
    static func == (lhs: Song, rhs: Song) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Text notation

/// Parses the compact notation used in songs.json:
///
///     "E4:1 D4 C4 D4 | E4 E4 E4:2 | C4+E4+G4:4 | r:1 …"
///
/// * Tokens are separated by whitespace; `|` bar lines are for readability only.
/// * `:<beats>` sets a duration that carries over to following tokens (default 1).
/// * `+` joins notes that start together (a chord); `r` is a rest.
enum NotationParser {
    struct ParseError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    struct Result {
        var notes: [NoteEvent]
        var length: Double
    }

    static func parse(_ text: String, hand: Hand, firstID: Int = 0) throws -> Result {
        var time = 0.0
        var duration = 1.0
        var id = firstID
        var notes: [NoteEvent] = []

        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            if token == "|" { continue }
            let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let head = parts[0]
            if parts.count == 2 {
                guard let d = Double(parts[1]), d > 0 else {
                    throw ParseError(message: "Invalid duration in \"\(token)\"")
                }
                duration = d
            }
            if head != "r" {
                for chordTone in head.split(separator: "+") {
                    guard let spelled = MusicTheory.parse(chordTone) else {
                        throw ParseError(message: "Invalid pitch \"\(chordTone)\" in \"\(token)\"")
                    }
                    notes.append(NoteEvent(id: id, pitch: spelled.midi, start: time, duration: duration,
                                           hand: hand, staffStep: spelled.staffStep,
                                           accidental: spelled.accidental))
                    id += 1
                }
            }
            time += duration
        }
        return Result(notes: notes, length: time)
    }
}

// MARK: - JSON

/// The JSON shape shared by songs and lesson exercises.
struct SongDefinition: Decodable {
    let id: String
    let title: String?
    let composer: String?
    let level: Level?
    let genre: String?
    let tempo: Double
    let beatsPerBar: Int?
    let beatUnit: Int?
    let pickup: Double?
    let key: String?
    let right: String?
    let left: String?

    func makeSong(id overrideID: String? = nil, title overrideTitle: String? = nil,
                  composer overrideComposer: String? = nil, level overrideLevel: Level? = nil) throws -> Song {
        let right = try NotationParser.parse(self.right ?? "", hand: .right, firstID: 0)
        let left = try NotationParser.parse(self.left ?? "", hand: .left, firstID: right.notes.count)
        return Song(
            id: overrideID ?? id,
            title: overrideTitle ?? title ?? id,
            composer: overrideComposer ?? composer ?? "",
            level: overrideLevel ?? level ?? .beginner,
            genre: genre ?? "Exercise",
            tempo: tempo,
            beatsPerBar: beatsPerBar ?? 4,
            beatUnit: beatUnit ?? 4,
            pickup: pickup ?? 0,
            keyName: key ?? "C major",
            notes: right.notes + left.notes,
            totalBeats: max(right.length, left.length)
        )
    }
}
