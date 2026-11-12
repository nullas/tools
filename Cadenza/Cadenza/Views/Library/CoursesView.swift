import SwiftUI

struct CoursesView: View {
    let play: (PlayRequest) -> Void
    @Environment(Library.self) private var library

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(library.courses) { course in
                        NavigationLink(value: course) { CourseCard(course: course) }
                            .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Courses")
            .navigationDestination(for: Course.self) { CourseDetailView(course: $0) }
            .navigationDestination(for: Lesson.self) { LessonView(lesson: $0, play: play) }
        }
    }
}

private struct CourseCard: View {
    let course: Course
    @Environment(ProgressStore.self) private var progress

    private var completed: Int {
        course.lessons.filter { (progress.record(for: $0.id)?.stars ?? 0) > 0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: course.symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                LevelBadge(level: course.level)
                    .background(.white, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(course.title).font(.title2.bold()).foregroundStyle(.white)
                Text(course.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(completed), total: Double(max(course.lessons.count, 1)))
                    .tint(.white)
                Text("\(completed) of \(course.lessons.count) lessons")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Theme.color(for: course.level), Theme.color(for: course.level).opacity(0.65)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

struct CourseDetailView: View {
    let course: Course
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        List {
            Section {
                Text(course.subtitle).foregroundStyle(.secondary)
            }
            Section("Lessons") {
                ForEach(Array(course.lessons.enumerated()), id: \.element.id) { index, lesson in
                    NavigationLink(value: lesson) {
                        HStack(spacing: 14) {
                            let stars = progress.record(for: lesson.id)?.stars ?? 0
                            ZStack {
                                Circle().fill(stars > 0 ? Theme.accent : Color(.tertiarySystemFill))
                                if stars > 0 {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                } else {
                                    Text("\(index + 1)").font(.caption.bold())
                                }
                            }
                            .frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(lesson.title).font(.body.weight(.medium))
                                if stars > 0 { StarsView(stars: stars, size: 10) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(course.title)
    }
}

struct LessonView: View {
    let lesson: Lesson
    let play: (PlayRequest) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(lesson.title).font(.largeTitle.bold())
                ForEach(lesson.body, id: \.self) { paragraph in
                    Text(paragraph).font(.body).fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    ForEach(Array(lesson.song.hands).sorted { $0.rawValue < $1.rawValue }, id: \.self) { hand in
                        Label(hand.title, systemImage: "hand.raised.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(Theme.color(for: hand))
                            .background(Theme.color(for: hand).opacity(0.15), in: Capsule())
                    }
                    Text("\(lesson.song.barCount) bars · \(Int(lesson.song.tempo)) BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    Button {
                        play(PlayRequest(song: lesson.song, mode: .practice, hands: .both))
                    } label: {
                        Label("Start exercise", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        play(PlayRequest(song: lesson.song, mode: .listen, hands: .both))
                    } label: {
                        Label("Listen", systemImage: "headphones")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
