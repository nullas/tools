import Foundation
import Observation

struct DayPractice: Identifiable {
    let date: Date
    let minutes: Double
    var id: Date { date }
}

struct SongRecord: Codable, Equatable {
    var bestAccuracy: Double = 0
    var stars: Int = 0
    var plays: Int = 0
    var lastPlayed: Date?
}

/// Practice history, persisted as JSON in UserDefaults.
@Observable
final class ProgressStore {
    private struct Snapshot: Codable {
        var records: [String: SongRecord] = [:]
        var dailySeconds: [String: Double] = [:]
        var dailyGoalMinutes: Int = 10
    }

    private(set) var records: [String: SongRecord]
    private(set) var dailySeconds: [String: Double]
    private(set) var dailyGoalMinutes: Int

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "progress.v1"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let snapshot = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
        records = snapshot.records
        dailySeconds = snapshot.dailySeconds
        dailyGoalMinutes = snapshot.dailyGoalMinutes
    }

    // MARK: Recording

    func record(songID: String, accuracy: Double, stars: Int, at date: Date = Date()) {
        var r = records[songID] ?? SongRecord()
        r.plays += 1
        r.lastPlayed = date
        r.bestAccuracy = max(r.bestAccuracy, accuracy)
        r.stars = max(r.stars, stars)
        records[songID] = r
        save()
    }

    func addPractice(seconds: Double, at date: Date = Date()) {
        guard seconds > 0.5 else { return }
        dailySeconds[Self.dayFormatter.string(from: date), default: 0] += seconds
        save()
    }

    func setDailyGoal(minutes: Int) {
        dailyGoalMinutes = min(max(minutes, 5), 120)
        save()
    }

    func reset() {
        records = [:]
        dailySeconds = [:]
        save()
    }

    // MARK: Queries

    func record(for songID: String) -> SongRecord? { records[songID] }

    func minutes(on date: Date) -> Double {
        (dailySeconds[Self.dayFormatter.string(from: date)] ?? 0) / 60
    }

    var todayMinutes: Double { minutes(on: Date()) }
    var totalMinutes: Double { dailySeconds.values.reduce(0, +) / 60 }
    var totalStars: Int { records.values.reduce(0) { $0 + $1.stars } }

    /// Consecutive days with practice, ending today (or yesterday, if today has none yet).
    func streak(today: Date = Date()) -> Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: today)
        if minutes(on: day) <= 0 { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while minutes(on: day) > 0 {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    /// Practice minutes for each of the last `days` days, oldest first.
    func recentDays(_ days: Int = 7, today: Date = Date()) -> [DayPractice] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: today)
        return (0..<days).reversed().compactMap { offset in
            cal.date(byAdding: .day, value: -offset, to: start).map { DayPractice(date: $0, minutes: minutes(on: $0)) }
        }
    }

    func recentlyPlayedIDs(limit: Int = 5) -> [String] {
        records.filter { $0.value.lastPlayed != nil }
            .sorted { ($0.value.lastPlayed ?? .distantPast) > ($1.value.lastPlayed ?? .distantPast) }
            .prefix(limit)
            .map(\.key)
    }

    private func save() {
        let snapshot = Snapshot(records: records, dailySeconds: dailySeconds, dailyGoalMinutes: dailyGoalMinutes)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
    }
}
