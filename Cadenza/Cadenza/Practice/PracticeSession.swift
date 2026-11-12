import Foundation
import Observation
import QuartzCore

enum HandSelection: String, CaseIterable, Identifiable {
    case left, both, right

    var id: String { rawValue }
    var shortTitle: String {
        switch self {
        case .left: return "L"
        case .both: return "L+R"
        case .right: return "R"
        }
    }

    func includes(_ hand: Hand) -> Bool {
        switch self {
        case .both: return true
        case .left: return hand == .left
        case .right: return hand == .right
        }
    }
}

enum PlayMode {
    /// The player plays the selected hands and is scored.
    case practice
    /// The app plays the whole piece as a demonstration.
    case listen
}

enum NoteState {
    case hit, missed
}

struct SessionResult: Equatable {
    let accuracy: Double
    let stars: Int
    let hits: Int
    let total: Int
    let mistakes: Int
    let seconds: Double
}

/// A group of notes that start together and must be played together.
struct PracticeStep {
    let beat: Double
    let notes: [NoteEvent]
}

/// Drives one run through a song: moves the playhead, waits for the player in wait mode,
/// plays the other hand, scores the notes and handles loops.
@Observable
final class PracticeSession: NoteReceiver {
    let song: Song
    let mode: PlayMode

    // Settings the player can change while practising.
    private(set) var hands: HandSelection
    var waitMode = true
    var speed = 1.0
    /// Play the hand the user is not practising.
    var accompany = true
    var metronome = false
    private(set) var loop: ClosedRange<Int>?

    // Playback state.
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false
    private(set) var isFinished = false
    private(set) var result: SessionResult?
    private(set) var noteStates: [Int: NoteState] = [:]
    private(set) var pressed: Set<Int> = []
    private(set) var wrongPitches: Set<Int> = []
    private(set) var mistakes = 0
    private(set) var practiceSeconds: Double = 0
    private(set) var steps: [PracticeStep] = []
    private(set) var stepIndex = 0
    /// Notes of the current step that are already played (wait mode).
    private(set) var satisfied: Set<Int> = []

    @ObservationIgnored var onExpectedNotesChanged: ((Set<Int>) -> Void)?
    @ObservationIgnored var onFinish: ((SessionResult) -> Void)?

    @ObservationIgnored private let synth: PianoSynth?
    @ObservationIgnored private let driver = FrameDriver()
    @ObservationIgnored private var autoNotes: [NoteEvent] = []
    @ObservationIgnored private var autoIndex = 0
    @ObservationIgnored private var sounding: [(pitch: Int, end: Double)] = []
    @ObservationIgnored private var lastPublishedExpected: Set<Int> = []

    /// Beats counted in before the first note.
    var leadIn: Double { Double(song.beatsPerBar) }
    var beatsPerSecond: Double { song.tempo / 60 * speed }
    /// How far from the playhead a note may be played and still count, in beats.
    var hitWindow: Double { max(0.2, 0.18 * beatsPerSecond) }
    var progress: Double { min(1, max(0, playhead / max(song.totalBeats, 1))) }
    var currentBar: Int { song.bar(at: max(0, playhead)) }

    init(song: Song, mode: PlayMode = .practice, hands: HandSelection = .both, synth: PianoSynth? = .shared) {
        self.song = song
        self.mode = mode
        self.hands = hands
        self.synth = synth
        driver.onFrame = { [weak self] dt in self?.tick(dt) }
        rebuild()
    }

    deinit { driver.stop() }

    // MARK: Configuration

    func setHands(_ selection: HandSelection) {
        guard selection != hands else { return }
        hands = selection
        rebuild()
    }

    func setLoop(_ bars: ClosedRange<Int>?) {
        if let bars {
            let upper = min(bars.upperBound, song.barCount - 1)
            loop = min(bars.lowerBound, upper)...upper
        } else {
            loop = nil
        }
        reset()
    }

    /// Whether a note belongs to the hands the player is practising.
    func isActive(_ note: NoteEvent) -> Bool {
        mode == .practice && hands.includes(note.hand)
    }

    private func rebuild() {
        let active = song.notes.filter(isActive)
        let grouped = Dictionary(grouping: active) { ($0.start * 1_000).rounded() }
        steps = grouped.keys.sorted().map { key in
            let notes = grouped[key]!.sorted { $0.pitch < $1.pitch }
            return PracticeStep(beat: notes[0].start, notes: notes)
        }
        autoNotes = song.notes.filter { !isActive($0) }
        reset()
    }

    // MARK: Transport

    func play() {
        if isFinished { reset() }
        guard !isPlaying else { return }
        isPlaying = true
        synth?.start()
        driver.start()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        driver.stop()
        releaseSounding()
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func stop() {
        pause()
        synth?.allNotesOff()
    }

    /// Back to the start of the song (or of the loop), paused.
    func reset() {
        pause()
        isFinished = false
        result = nil
        mistakes = 0
        noteStates = [:]
        wrongPitches = []
        let start = loop.map { song.barStart($0.lowerBound) } ?? 0
        position(at: start - leadIn, clearingFrom: -.infinity)
    }

    /// Moves the playhead while paused (scrubbing). Notes from the new position onwards are un-scored.
    func seek(to beat: Double) {
        let lower = -leadIn
        let upper = song.totalBeats
        position(at: min(max(beat, lower), upper), clearingFrom: beat - 1e-6)
    }

    private func position(at beat: Double, clearingFrom clearBeat: Double) {
        releaseSounding()
        playhead = beat
        satisfied = []
        if clearBeat.isFinite {
            for note in song.notes where note.start >= clearBeat { noteStates[note.id] = nil }
        }
        // Notes before a loop's first bar are not part of the exercise, even during the count-in.
        let first = max(beat, loop.map { song.barStart($0.lowerBound) } ?? -.infinity) - 1e-6
        stepIndex = steps.firstIndex { $0.beat >= first } ?? steps.count
        autoIndex = autoNotes.firstIndex { $0.start >= first } ?? autoNotes.count
        publishExpected()
    }

    // MARK: Clock

    /// Advances the song by `dt` seconds of wall-clock time.
    func tick(_ dt: Double) {
        guard isPlaying, dt > 0 else { return }
        practiceSeconds += dt
        let old = playhead
        var target = old + dt * beatsPerSecond
        let loopEnd = loop.map { song.barEnd($0.upperBound) }

        if mode == .practice, waitMode, stepIndex < steps.count {
            let next = steps[stepIndex].beat
            if loopEnd == nil || next < loopEnd! - 1e-6 {
                target = min(target, next)
            }
        }
        if target <= old { return }

        if metronome {
            var beat = floor(old) + 1
            if beat <= old { beat += 1 }
            while beat <= target + 1e-9 {
                if beat >= -leadIn { synth?.click(accent: song.isDownbeat(beat)) }
                beat += 1
            }
        }

        // The other hand, or everything in listen mode.
        while autoIndex < autoNotes.count, autoNotes[autoIndex].start < target {
            let note = autoNotes[autoIndex]
            if mode == .listen || accompany {
                synth?.noteOn(note.pitch, velocity: 0.55)
                sounding.append((note.pitch, note.end))
            }
            if mode == .listen { noteStates[note.id] = .hit }
            autoIndex += 1
        }
        sounding.removeAll { item in
            if item.end <= target { synth?.noteOff(item.pitch); return true }
            return false
        }

        // Free-tempo mode: anything the playhead has left behind is missed.
        if mode == .practice, !waitMode {
            var changed = false
            while stepIndex < steps.count, steps[stepIndex].beat + hitWindow < target {
                for note in steps[stepIndex].notes where noteStates[note.id] == nil {
                    noteStates[note.id] = .missed
                }
                stepIndex += 1
                changed = true
            }
            if changed { publishExpected() }
        }

        playhead = target

        if let loopEnd, playhead >= loopEnd {
            restartLoop()
            return
        }
        if playhead >= song.totalBeats + 0.25, stepIndex >= steps.count {
            finish()
        } else if mode == .practice, !waitMode {
            publishExpected()
        }
    }

    private func restartLoop() {
        guard let loop else { return }
        let start = song.barStart(loop.lowerBound)
        position(at: start - min(leadIn, 2), clearingFrom: start - 1e-6)
    }

    private func finish() {
        isPlaying = false
        isFinished = true
        driver.stop()
        releaseSounding()
        let r = score()
        result = r
        publishExpected()
        if mode == .practice { onFinish?(r) }
    }

    func score() -> SessionResult {
        let total = steps.reduce(0) { $0 + $1.notes.count }
        let hits = noteStates.values.filter { $0 == .hit }.count
        let accuracy: Double
        if total == 0 {
            accuracy = 1
        } else if waitMode {
            accuracy = Double(hits) / Double(max(1, hits + mistakes))
        } else {
            accuracy = Double(hits) / Double(total + mistakes)
        }
        let stars: Int
        switch accuracy {
        case 0.95...: stars = 3
        case 0.8..<0.95: stars = 2
        case 0.5..<0.8: stars = 1
        default: stars = 0
        }
        return SessionResult(accuracy: accuracy, stars: stars, hits: hits, total: total,
                             mistakes: mistakes, seconds: practiceSeconds)
    }

    // MARK: Input

    func noteOn(_ pitch: Int, velocity: Int, source: InputSource) {
        pressed.insert(pitch)
        guard mode == .practice, !isFinished, stepIndex < steps.count else { return }

        if waitMode {
            let step = steps[stepIndex]
            let matching = step.notes.filter { $0.pitch == pitch }
            if !isPlaying {
                // Playing the first expected note starts the song.
                guard !matching.isEmpty else { return }
                if playhead < step.beat {
                    playhead = step.beat
                    autoIndex = autoNotes.firstIndex { $0.start >= step.beat - 1e-6 } ?? autoNotes.count
                }
                play()
            }
            // Allow a beat of anticipation; ignore notes played far ahead of the music.
            guard step.beat - playhead <= 1.0 else { return }
            if matching.isEmpty {
                registerMistake(pitch)
                return
            }
            for note in matching where !satisfied.contains(note.id) {
                satisfied.insert(note.id)
                noteStates[note.id] = .hit
            }
            if step.notes.allSatisfy({ satisfied.contains($0.id) }) {
                stepIndex += 1
                satisfied = []
            }
            publishExpected()
        } else {
            guard isPlaying else { return }
            var index = stepIndex
            while index < steps.count, steps[index].beat <= playhead + hitWindow {
                let step = steps[index]
                if abs(step.beat - playhead) <= hitWindow {
                    let matching = step.notes.filter { $0.pitch == pitch && noteStates[$0.id] == nil }
                    if !matching.isEmpty {
                        matching.forEach { noteStates[$0.id] = .hit }
                        publishExpected()
                        return
                    }
                }
                index += 1
            }
            registerMistake(pitch)
        }
    }

    func noteOff(_ pitch: Int, source: InputSource) {
        pressed.remove(pitch)
    }

    private func registerMistake(_ pitch: Int) {
        mistakes += 1
        wrongPitches.insert(pitch)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.wrongPitches.remove(pitch)
        }
    }

    // MARK: Highlighting

    /// The notes the player should be playing right now.
    var expectedNotes: [NoteEvent] {
        guard mode == .practice, !isFinished else { return [] }
        if waitMode {
            guard stepIndex < steps.count else { return [] }
            let step = steps[stepIndex]
            guard step.beat - playhead <= 1.0 else { return [] }
            return step.notes.filter { !satisfied.contains($0.id) }
        }
        var notes: [NoteEvent] = []
        var index = stepIndex
        while index < steps.count, steps[index].beat <= playhead + hitWindow {
            notes += steps[index].notes.filter { noteStates[$0.id] == nil }
            index += 1
        }
        return notes
    }

    /// Notes the app is playing on its own (listen mode or accompaniment), for lighting keys.
    var soundingAutoNotes: [NoteEvent] {
        autoNotes.filter { $0.start <= playhead && $0.end > playhead }
    }

    /// Sends the current expected notes to `onExpectedNotesChanged` even if they have not changed.
    func refreshExpectedNotes() {
        lastPublishedExpected = [-1]
        publishExpected()
    }

    private func publishExpected() {
        let pitches: Set<Int>
        if mode == .practice, stepIndex < steps.count {
            // Listen for the next step as soon as it is close; the detector needs a moment.
            var upcoming = Set(steps[stepIndex].notes.filter { !satisfied.contains($0.id) }.map(\.pitch))
            if !waitMode, stepIndex + 1 < steps.count, steps[stepIndex + 1].beat - playhead < 1 {
                upcoming.formUnion(steps[stepIndex + 1].notes.map(\.pitch))
            }
            pitches = upcoming
        } else {
            pitches = []
        }
        if pitches != lastPublishedExpected {
            lastPublishedExpected = pitches
            onExpectedNotesChanged?(pitches)
        }
    }

    private func releaseSounding() {
        for item in sounding { synth?.noteOff(item.pitch) }
        sounding.removeAll()
    }
}

/// Calls `onFrame` with the time since the previous frame, once per screen refresh.
final class FrameDriver: NSObject {
    var onFrame: ((Double) -> Void)?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    func start() {
        stop()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else { return }
        onFrame?(min(link.timestamp - lastTimestamp, 0.1))
    }
}
