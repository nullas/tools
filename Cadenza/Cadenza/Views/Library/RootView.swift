import SwiftUI

struct RootView: View {
    @State private var playRequest: PlayRequest?

    var body: some View {
        TabView {
            HomeView(play: play)
                .tabItem { Label("Home", systemImage: "house.fill") }
            SongsView(play: play)
                .tabItem { Label("Songs", systemImage: "music.note.list") }
            CoursesView(play: play)
                .tabItem { Label("Courses", systemImage: "graduationcap.fill") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerView(request: request)
        }
    }

    private func play(_ request: PlayRequest) {
        playRequest = request
    }
}

// MARK: - Home

struct HomeView: View {
    let play: (PlayRequest) -> Void
    @Environment(Library.self) private var library
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    DailyGoalCard()
                        .padding(.horizontal)

                    if !recent.isEmpty {
                        section("Continue practising") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(recent) { song in
                                        NavigationLink(value: song) { SongTile(song: song) }
                                            .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    if let next = nextLesson {
                        section("Your next lesson") {
                            NavigationLink(value: next.lesson) {
                                NextLessonCard(course: next.course, lesson: next.lesson)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                        }
                    }

                    ForEach(Level.allCases) { level in
                        let songs = library.songs.filter { $0.level == level }
                        if !songs.isEmpty {
                            section("\(level.title) songs") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 14) {
                                        ForEach(songs) { song in
                                            NavigationLink(value: song) { SongTile(song: song) }
                                                .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle(greeting)
            .navigationDestination(for: Song.self) { SongDetailView(song: $0, play: play) }
            .navigationDestination(for: Lesson.self) { LessonView(lesson: $0, play: play) }
        }
    }

    private var recent: [Song] {
        progress.recentlyPlayedIDs().compactMap { id in library.songs.first { $0.id == id } }
    }

    private var nextLesson: (course: Course, lesson: Lesson)? {
        for course in library.courses {
            for lesson in course.lessons where (progress.record(for: lesson.id)?.stars ?? 0) == 0 {
                return (course, lesson)
            }
        }
        return nil
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).padding(.horizontal)
            content()
        }
    }
}

private struct DailyGoalCard: View {
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        let goal = Double(progress.dailyGoalMinutes)
        let today = progress.todayMinutes
        HStack(spacing: 18) {
            ZStack {
                ProgressRing(fraction: today / goal, lineWidth: 9)
                Text("\(Int(today.rounded(.down)))")
                    .font(.title2.bold().monospacedDigit())
            }
            .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(today >= goal ? "Daily goal reached" : "Daily goal")
                    .font(.headline)
                Text("\(Int(today.rounded(.down))) of \(Int(goal)) minutes today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label("\(progress.streak()) day streak", systemImage: "flame.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct SongTile: View {
    let song: Song
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SongCover(song: song, size: 140, cornerRadius: 18)
            Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(song.composer).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let record = progress.record(for: song.id) {
                StarsView(stars: record.stars, size: 10)
            }
        }
        .frame(width: 140)
    }
}

private struct NextLessonCard: View {
    let course: Course
    let lesson: Lesson

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: course.symbol)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Theme.color(for: course.level).gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(course.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(lesson.title).font(.headline)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Songs

struct SongsView: View {
    let play: (PlayRequest) -> Void
    @Environment(Library.self) private var library
    @State private var query = ""
    @State private var level: Level?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip("All", selected: level == nil) { level = nil }
                            ForEach(Level.allCases) { l in
                                filterChip(l.title, selected: level == l) { level = l }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                }
                ForEach(filtered) { song in
                    NavigationLink(value: song) { SongRow(song: song) }
                }
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Songs or composers")
            .navigationTitle("Songs")
            .navigationDestination(for: Song.self) { SongDetailView(song: $0, play: play) }
        }
    }

    private var filtered: [Song] {
        library.songs.filter { song in
            (level == nil || song.level == level) &&
            (query.isEmpty || song.title.localizedCaseInsensitiveContains(query) ||
             song.composer.localizedCaseInsensitiveContains(query))
        }
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Theme.accent : Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Song detail

struct SongDetailView: View {
    let song: Song
    let play: (PlayRequest) -> Void
    @Environment(ProgressStore.self) private var progress
    @State private var hands: HandSelection = .both

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                SongCover(song: song, size: 180, cornerRadius: 28)
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                    .padding(.top, 8)

                VStack(spacing: 6) {
                    Text(song.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(song.composer).font(.headline).foregroundStyle(.secondary)
                    LevelBadge(level: song.level)
                }

                HStack(spacing: 0) {
                    fact(song.formattedDuration(), "Length")
                    Divider().frame(height: 32)
                    fact("\(song.barCount)", "Bars")
                    Divider().frame(height: 32)
                    fact(song.timeSignature, "Time")
                    Divider().frame(height: 32)
                    fact("\(Int(song.tempo))", "BPM")
                }
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let record = progress.record(for: song.id) {
                    HStack {
                        StarsView(stars: record.stars, size: 16)
                        Spacer()
                        Text("Best \(Int((record.bestAccuracy * 100).rounded()))% · \(record.plays) plays")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }

                if song.hands.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Which hands?").font(.headline)
                        Picker("Hands", selection: $hands) {
                            Text("Left").tag(HandSelection.left)
                            Text("Both").tag(HandSelection.both)
                            Text("Right").tag(HandSelection.right)
                        }
                        .pickerStyle(.segmented)
                        Text(handsHint).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 12) {
                    Button {
                        play(PlayRequest(song: song, mode: .practice, hands: hands))
                    } label: {
                        Label("Start practising", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        play(PlayRequest(song: song, mode: .listen, hands: .both))
                    } label: {
                        Label("Listen first", systemImage: "headphones")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Text("Tip: turn the phone sideways for a wider view of the music.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var handsHint: String {
        switch hands {
        case .both: return "Play both hands. Wait mode holds the music until every note is down."
        case .left: return "Practise the left hand. The app plays the right hand for you."
        case .right: return "Practise the right hand. The app plays the left hand for you."
        }
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
