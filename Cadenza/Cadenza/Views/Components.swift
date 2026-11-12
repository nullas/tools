import SwiftUI

enum Theme {
    static let accent = Color(red: 0.11, green: 0.69, blue: 0.60)
    static let rightHand = Color(red: 0.26, green: 0.55, blue: 0.98)
    static let leftHand = Color(red: 0.98, green: 0.58, blue: 0.22)
    static let hit = Color(red: 0.22, green: 0.78, blue: 0.42)
    static let miss = Color(red: 0.93, green: 0.30, blue: 0.30)
    static let paper = Color(red: 0.985, green: 0.975, blue: 0.95)
    static let ink = Color(red: 0.13, green: 0.13, blue: 0.16)
    static let stage = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let stageRaised = Color(red: 0.13, green: 0.14, blue: 0.17)

    static func color(for hand: Hand) -> Color {
        hand == .right ? rightHand : leftHand
    }

    static func color(for level: Level) -> Color {
        switch level {
        case .beginner: return Color(red: 0.30, green: 0.75, blue: 0.45)
        case .easy: return Color(red: 0.25, green: 0.60, blue: 0.95)
        case .intermediate: return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .advanced: return Color(red: 0.88, green: 0.30, blue: 0.40)
        }
    }

    /// A stable pair of colours derived from a string (Swift's `hashValue` changes between launches).
    static func gradient(for seed: String) -> [Color] {
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360
        return [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.55)]
    }
}

struct SongCover: View {
    let song: Song
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            LinearGradient(colors: Theme.gradient(for: song.id), startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: song.genre == "Exercise" ? "pianokeys" : "music.quarternote.3")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct LevelBadge: View {
    let level: Level

    var body: some View {
        Text(level.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(Theme.color(for: level))
            .background(Theme.color(for: level).opacity(0.15), in: Capsule())
    }
}

struct StarsView: View {
    let stars: Int
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: i < stars ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(i < stars ? Color.yellow : Color.secondary.opacity(0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stars) of 3 stars")
    }
}

struct SongRow: View {
    let song: Song
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        HStack(spacing: 14) {
            SongCover(song: song)
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title).font(.headline).lineLimit(1)
                Text(song.composer).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    LevelBadge(level: song.level)
                    if let record = progress.record(for: song.id), record.plays > 0 {
                        StarsView(stars: record.stars, size: 10)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 8
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// What the full-screen player should open.
struct PlayRequest: Identifiable {
    let id = UUID()
    let song: Song
    let mode: PlayMode
    let hands: HandSelection
}
