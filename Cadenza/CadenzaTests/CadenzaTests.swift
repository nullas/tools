import XCTest
@testable import Cadenza

final class NotationParserTests: XCTestCase {
    func testPitchParsing() {
        XCTAssertEqual(MusicTheory.parse("C4"), SpelledPitch(midi: 60, staffStep: 28, accidental: 0))
        XCTAssertEqual(MusicTheory.parse("A4")?.midi, 69)
        XCTAssertEqual(MusicTheory.parse("F#5"), SpelledPitch(midi: 78, staffStep: 38, accidental: 1))
        XCTAssertEqual(MusicTheory.parse("Bb3"), SpelledPitch(midi: 58, staffStep: 27, accidental: -1))
        XCTAssertEqual(MusicTheory.parse("C-1")?.midi, 0)
        XCTAssertNil(MusicTheory.parse("H4"))
        XCTAssertNil(MusicTheory.parse("C"))
    }

    func testDurationsCarryOverAndRestsAdvanceTime() throws {
        let result = try NotationParser.parse("C4:0.5 D4 | r:1 E4+G4:2", hand: .right)
        XCTAssertEqual(result.length, 4)
        XCTAssertEqual(result.notes.map(\.pitch), [60, 62, 64, 67])
        XCTAssertEqual(result.notes.map(\.start), [0, 0.5, 2, 2])
        XCTAssertEqual(result.notes.map(\.duration), [0.5, 0.5, 2, 2])
        XCTAssertEqual(Set(result.notes.map(\.id)).count, 4)
    }

    func testInvalidTokensThrow() {
        XCTAssertThrowsError(try NotationParser.parse("C4:0", hand: .right))
        XCTAssertThrowsError(try NotationParser.parse("X9", hand: .right))
    }

    func testBarsAndPickup() throws {
        let def = try JSONDecoder().decode(SongDefinition.self, from: Data("""
        {"id":"t","tempo":120,"beatsPerBar":3,"pickup":1,"right":"C4 | D4:3 | E4:2"}
        """.utf8))
        let song = try def.makeSong()
        XCTAssertEqual(song.totalBeats, 6)
        XCTAssertEqual(song.barStarts, [0, 1, 4])
        XCTAssertEqual(song.bar(at: 2.5), 1)
        XCTAssertTrue(song.isDownbeat(4))
        XCTAssertFalse(song.isDownbeat(5))
    }
}

final class LibraryTests: XCTestCase {
    func testBundledContentLoadsWithoutErrors() {
        let library = Library()
        XCTAssertEqual(library.loadErrors, [])
        XCTAssertGreaterThanOrEqual(library.songs.count, 9)
        XCTAssertFalse(library.courses.isEmpty)
        for song in library.songs {
            XCTAssertFalse(song.notes.isEmpty, song.title)
            XCTAssertGreaterThan(song.barCount, 1, song.title)
        }
    }
}

final class PracticeSessionTests: XCTestCase {
    private func song(right: String, left: String = "", tempo: Double = 60) throws -> Song {
        let r = try NotationParser.parse(right, hand: .right)
        let l = try NotationParser.parse(left, hand: .left, firstID: r.notes.count)
        return Song(id: "test", title: "Test", composer: "", level: .beginner, genre: "Test",
                    tempo: tempo, beatsPerBar: 4, keyName: "C", notes: r.notes + l.notes,
                    totalBeats: max(r.length, l.length))
    }

    func testWaitModeHoldsUntilCorrectNote() throws {
        let session = PracticeSession(song: try song(right: "C4 D4 E4 F4"), synth: nil)
        session.play()
        session.tick(10)
        XCTAssertEqual(session.playhead, 0, "playhead waits at the first note")

        session.noteOn(61, velocity: 90, source: .touch)
        XCTAssertEqual(session.mistakes, 1)
        XCTAssertEqual(session.stepIndex, 0)

        session.noteOn(60, velocity: 90, source: .touch)
        XCTAssertEqual(session.stepIndex, 1)
        session.tick(10)
        XCTAssertEqual(session.playhead, 1)
    }

    func testChordNeedsEveryNote() throws {
        let session = PracticeSession(song: try song(right: "C4+E4+G4:4"), synth: nil)
        session.play()
        session.tick(10)
        session.noteOn(60, velocity: 90, source: .midi)
        session.noteOn(64, velocity: 90, source: .midi)
        XCTAssertEqual(session.stepIndex, 0)
        XCTAssertEqual(Set(session.expectedNotes.map(\.pitch)), [67])
        session.noteOn(67, velocity: 90, source: .midi)
        XCTAssertEqual(session.stepIndex, 1)
    }

    func testFinishingScoresThreeStarsWithoutMistakes() throws {
        let session = PracticeSession(song: try song(right: "C4 D4"), synth: nil)
        var finished: SessionResult?
        session.onFinish = { finished = $0 }
        session.play()
        session.tick(10); session.noteOn(60, velocity: 90, source: .touch)
        session.tick(10); session.noteOn(62, velocity: 90, source: .touch)
        session.tick(10)
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(finished?.stars, 3)
        XCTAssertEqual(finished?.hits, 2)
    }

    func testFirstNoteStartsSongAndSkipsCountIn() throws {
        let session = PracticeSession(song: try song(right: "E4 D4"), synth: nil)
        XCTAssertFalse(session.isPlaying)
        session.noteOn(64, velocity: 90, source: .touch)
        XCTAssertTrue(session.isPlaying)
        XCTAssertEqual(session.stepIndex, 1)
        session.stop()
    }

    func testFreeTempoMarksNotesMissed() throws {
        let session = PracticeSession(song: try song(right: "C4 D4 E4 F4"), synth: nil)
        session.waitMode = false
        session.play()
        session.tick(4)          // count-in ends exactly on beat 0
        session.noteOn(60, velocity: 90, source: .touch)
        session.tick(20)
        XCTAssertTrue(session.isFinished)
        let result = try XCTUnwrap(session.result)
        XCTAssertEqual(result.hits, 1)
        XCTAssertEqual(result.total, 4)
        XCTAssertEqual(session.noteStates.values.filter { $0 == .missed }.count, 3)
    }

    func testHandSelectionOnlyScoresChosenHand() throws {
        let session = PracticeSession(song: try song(right: "C5:4", left: "C3:4"), synth: nil)
        session.setHands(.left)
        XCTAssertEqual(session.steps.count, 1)
        XCTAssertEqual(session.steps[0].notes.map(\.pitch), [48])
    }

    func testLoopReturnsToLoopStart() throws {
        let session = PracticeSession(song: try song(right: "C4:4 | D4:4 | E4:4"), synth: nil)
        session.setLoop(1...1)
        session.waitMode = false
        session.play()
        XCTAssertLessThan(session.playhead, 4)
        session.tick(1.0)
        session.tick(1.0)
        session.tick(1.0)
        session.tick(1.0)
        session.tick(1.0)
        session.tick(1.0)
        session.tick(1.0)
        session.tick(1.0)
        XCTAssertFalse(session.isFinished)
        XCTAssertGreaterThanOrEqual(session.playhead, 2)
        XCTAssertLessThan(session.playhead, 8)
    }
}

final class ProgressStoreTests: XCTestCase {
    func testRecordsBestScoreAndStreak() {
        let defaults = UserDefaults(suiteName: "cadenza.tests.\(UUID().uuidString)")!
        let store = ProgressStore(defaults: defaults)
        store.record(songID: "a", accuracy: 0.9, stars: 2)
        store.record(songID: "a", accuracy: 0.7, stars: 1)
        XCTAssertEqual(store.record(for: "a")?.stars, 2)
        XCTAssertEqual(store.record(for: "a")?.plays, 2)

        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        store.addPractice(seconds: 120, at: yesterday)
        store.addPractice(seconds: 60, at: today)
        XCTAssertEqual(store.streak(today: today), 2)
        XCTAssertEqual(store.minutes(on: today), 1, accuracy: 0.001)

        let reloaded = ProgressStore(defaults: defaults)
        XCTAssertEqual(reloaded.record(for: "a")?.bestAccuracy, 0.9)
    }
}
