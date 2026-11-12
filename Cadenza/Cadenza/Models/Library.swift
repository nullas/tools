import Foundation
import Observation

struct Lesson: Identifiable, Hashable {
    let id: String
    let title: String
    let body: [String]
    let song: Song
}

struct Course: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let level: Level
    let lessons: [Lesson]
}

private struct LessonDefinition: Decodable {
    let id: String
    let title: String
    let body: [String]
    let song: SongDefinition

    enum CodingKeys: String, CodingKey { case id, title, body }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent([String].self, forKey: .body) ?? []
        song = try SongDefinition(from: decoder)
    }
}

private struct CourseDefinition: Decodable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let level: Level
    let lessons: [LessonDefinition]
}

/// All bundled songs and courses, loaded once from JSON.
@Observable
final class Library {
    let songs: [Song]
    let courses: [Course]
    /// Problems found while loading; shown in Settings so broken content is never silently dropped.
    let loadErrors: [String]

    init(bundle: Bundle = .main) {
        var errors: [String] = []
        var songs: [Song] = []
        var courses: [Course] = []

        do {
            for def in try Library.decode([SongDefinition].self, resource: "songs", bundle: bundle) {
                do { songs.append(try def.makeSong()) } catch { errors.append("\(def.id): \(error)") }
            }
        } catch {
            errors.append("songs.json: \(error)")
        }

        do {
            for def in try Library.decode([CourseDefinition].self, resource: "courses", bundle: bundle) {
                var lessons: [Lesson] = []
                for l in def.lessons {
                    do {
                        let song = try l.song.makeSong(id: "lesson.\(def.id).\(l.id)", title: l.title,
                                                       composer: def.title, level: def.level)
                        lessons.append(Lesson(id: song.id, title: l.title, body: l.body, song: song))
                    } catch {
                        errors.append("\(def.id)/\(l.id): \(error)")
                    }
                }
                courses.append(Course(id: def.id, title: def.title, subtitle: def.subtitle,
                                      symbol: def.symbol, level: def.level, lessons: lessons))
            }
        } catch {
            errors.append("courses.json: \(error)")
        }

        self.songs = songs.sorted { ($0.level.rank, $0.title) < ($1.level.rank, $1.title) }
        self.courses = courses
        self.loadErrors = errors
    }

    func song(id: String) -> Song? {
        songs.first { $0.id == id } ?? courses.lazy.flatMap(\.lessons).first { $0.song.id == id }?.song
    }

    private static func decode<T: Decodable>(_ type: T.Type, resource: String, bundle: Bundle) throws -> T {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw NotationParser.ParseError(message: "\(resource).json is missing from the app bundle")
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
