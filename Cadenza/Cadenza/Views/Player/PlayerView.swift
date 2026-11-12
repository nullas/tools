import SwiftUI

enum NotationDisplay: String {
    case sheet, waterfall
}

/// The full-screen practice screen: notation on top, keyboard below.
struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(InputManager.self) private var input
    @Environment(ProgressStore.self) private var progress
    @AppStorage("player.display") private var display: NotationDisplay = .sheet
    @State private var session: PracticeSession
    @State private var showLoopEditor = false
    private let keyRange: (low: Int, high: Int)

    init(request: PlayRequest) {
        _session = State(initialValue: PracticeSession(song: request.song, mode: request.mode, hands: request.hands))
        keyRange = KeyboardLayout.range(for: request.song)
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            VStack(spacing: 0) {
                PlayerHeader(session: session, display: $display, showLoopEditor: $showLoopEditor, onClose: close)
                ProgressStrip(session: session)
                notation
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                KeyboardView(low: keyRange.low, high: keyRange.high, highlights: highlights,
                             pressed: session.pressed, wrong: session.wrongPitches,
                             showLabels: input.showNoteNames,
                             onDown: { input.touchDown($0) }, onUp: { input.touchUp($0) })
                    .frame(height: landscape ? max(100, geo.size.height * 0.3) : min(210, geo.size.height * 0.24))
            }
        }
        .background(Theme.stage.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay {
            if let result = session.result, session.mode == .practice {
                ResultsOverlay(result: result, onRetry: { session.reset() }, onClose: close)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: session.result)
        .sheet(isPresented: $showLoopEditor) {
            LoopEditor(session: session)
                .presentationDetents([.medium])
        }
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder
    private var notation: some View {
        let snapshot = NotationSnapshot(
            song: session.song,
            playhead: session.playhead,
            states: session.noteStates,
            expectedIDs: Set(session.expectedNotes.map(\.id)),
            hands: session.hands,
            mode: session.mode,
            loop: session.loop,
            showNames: input.showNoteNames
        )
        let canScrub = !session.isPlaying
        switch display {
        case .sheet:
            SheetMusicView(snapshot: snapshot, canScrub: canScrub) { session.seek(to: $0) }
        case .waterfall:
            WaterfallView(snapshot: snapshot, low: keyRange.low, high: keyRange.high, canScrub: canScrub) {
                session.seek(to: $0)
            }
        }
    }

    private var highlights: [Int: Color] {
        var colors: [Int: Color] = [:]
        if session.mode == .listen || session.accompany {
            for note in session.soundingAutoNotes {
                colors[note.pitch] = Theme.color(for: note.hand).opacity(session.mode == .listen ? 0.85 : 0.4)
            }
        }
        for note in session.expectedNotes {
            colors[note.pitch] = Theme.color(for: note.hand)
        }
        return colors
    }

    private func begin() {
        let input = self.input
        let progress = self.progress
        let songID = session.song.id
        input.receiver = session
        session.onExpectedNotesChanged = { [weak input] pitches in input?.setExpectedNotes(pitches) }
        session.onFinish = { [weak progress] result in
            progress?.record(songID: songID, accuracy: result.accuracy, stars: result.stars)
        }
        session.refreshExpectedNotes()
        input.beginListening()
        if session.mode == .listen { session.play() }
    }

    private func end() {
        session.stop()
        if input.receiver === session { input.receiver = nil }
        input.setExpectedNotes([])
        input.endListening()
        progress.addPractice(seconds: session.practiceSeconds)
    }

    private func close() {
        session.stop()
        dismiss()
    }
}

// MARK: - Header

private struct PlayerHeader: View {
    @Bindable var session: PracticeSession
    @Binding var display: NotationDisplay
    @Binding var showLoopEditor: Bool
    let onClose: () -> Void
    @Environment(InputManager.self) private var input

    private let speeds: [Double] = [0.25, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.25]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(Theme.stageRaised, in: Circle())
                }
                .accessibilityLabel("Close")

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.song.title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                InputIndicator()
                Button { session.reset() } label: {
                    Image(systemName: "backward.end.fill")
                        .frame(width: 36, height: 36)
                        .background(Theme.stageRaised, in: Circle())
                }
                .accessibilityLabel("Back to start")
                Button { session.togglePlay() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 46, height: 46)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if session.mode == .practice {
                        if session.song.hands.count > 1 { handPicker }
                        ControlChip(title: "Wait", systemImage: "hourglass", isOn: session.waitMode) {
                            session.waitMode.toggle()
                        }
                    }
                    speedMenu
                    ControlChip(title: session.loop.map { "Bars \($0.lowerBound + 1)–\($0.upperBound + 1)" } ?? "Loop",
                                systemImage: "repeat", isOn: session.loop != nil) {
                        showLoopEditor = true
                    }
                    if session.mode == .practice && session.hands != .both {
                        ControlChip(title: "Other hand", systemImage: "speaker.wave.2", isOn: session.accompany) {
                            session.accompany.toggle()
                        }
                    }
                    ControlChip(title: "Metronome", systemImage: "metronome", isOn: session.metronome) {
                        session.metronome.toggle()
                    }
                    ControlChip(title: "Names", systemImage: "textformat.abc", isOn: input.showNoteNames) {
                        input.setShowNoteNames(!input.showNoteNames)
                    }
                    ControlChip(title: display == .sheet ? "Sheet" : "Falling",
                                systemImage: display == .sheet ? "music.note.list" : "rectangle.split.3x1",
                                isOn: false) {
                        display = display == .sheet ? .waterfall : .sheet
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .foregroundStyle(.white)
    }

    private var subtitle: String {
        let bar = "Bar \(session.currentBar + 1) of \(session.song.barCount)"
        return session.mode == .listen ? "Listening · \(bar)" : bar
    }

    private var handPicker: some View {
        HStack(spacing: 2) {
            ForEach(HandSelection.allCases) { selection in
                Button { session.setHands(selection) } label: {
                    Text(selection.shortTitle)
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(session.hands == selection ? handColor(selection) : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selection == .both ? "Both hands" : (selection == .left ? "Left hand" : "Right hand"))
            }
        }
        .padding(2)
        .background(Theme.stageRaised, in: Capsule())
    }

    private func handColor(_ selection: HandSelection) -> Color {
        switch selection {
        case .left: return Theme.leftHand
        case .right: return Theme.rightHand
        case .both: return Theme.accent
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(speeds, id: \.self) { speed in
                Button {
                    session.speed = speed
                } label: {
                    if abs(speed - session.speed) < 0.001 {
                        Label("\(Int(speed * 100))%", systemImage: "checkmark")
                    } else {
                        Text("\(Int(speed * 100))%")
                    }
                }
            }
        } label: {
            ChipLabel(title: "\(Int((session.speed * 100).rounded()))%", systemImage: "speedometer",
                      isOn: session.speed < 0.999)
        }
    }
}

struct ChipLabel: View {
    let title: String
    let systemImage: String
    let isOn: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(isOn ? Theme.accent : Theme.stageRaised, in: Capsule())
            .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.85))
    }
}

struct ControlChip: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChipLabel(title: title, systemImage: systemImage, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Shows which inputs are live: a MIDI keyboard, and the microphone with its level.
private struct InputIndicator: View {
    @Environment(InputManager.self) private var input

    var body: some View {
        HStack(spacing: 10) {
            if !input.midiDevices.isEmpty {
                Image(systemName: "pianokeys")
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("MIDI keyboard connected")
            }
            switch input.micStatus {
            case .listening:
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.25))
                        .frame(width: 30, height: 30)
                        .scaleEffect(0.6 + CGFloat(input.micLevel) * 0.8)
                    Image(systemName: "mic.fill").foregroundStyle(Theme.accent)
                }
                .frame(width: 30, height: 30)
                .accessibilityLabel("Listening through the microphone")
            case .denied, .failed:
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(Theme.miss)
                    .accessibilityLabel("Microphone unavailable")
            case .requesting:
                ProgressView().controlSize(.small)
            case .off:
                EmptyView()
            }
        }
        .animation(.linear(duration: 0.08), value: input.micLevel)
    }
}

private struct ProgressStrip: View {
    let session: PracticeSession

    var body: some View {
        GeometryReader { geo in
            let total = max(session.song.totalBeats, 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08))
                if let loop = session.loop {
                    let x0 = geo.size.width * session.song.barStart(loop.lowerBound) / total
                    let x1 = geo.size.width * session.song.barEnd(loop.upperBound) / total
                    Rectangle().fill(Theme.accent.opacity(0.35))
                        .frame(width: max(2, x1 - x0))
                        .offset(x: x0)
                }
                Rectangle().fill(Theme.accent)
                    .frame(width: geo.size.width * session.progress)
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(session.progress * 100)) percent")
    }
}

// MARK: - Loop editor

private struct LoopEditor: View {
    let session: PracticeSession
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var from: Int
    @State private var to: Int

    init(session: PracticeSession) {
        self.session = session
        let current = session.currentBar
        let last = session.song.barCount - 1
        _enabled = State(initialValue: session.loop != nil)
        _from = State(initialValue: session.loop?.lowerBound ?? current)
        _to = State(initialValue: session.loop?.upperBound ?? min(current + 1, last))
    }

    var body: some View {
        let last = session.song.barCount - 1
        NavigationStack {
            Form {
                Section {
                    Toggle("Loop a section", isOn: $enabled)
                    if enabled {
                        Stepper("From bar \(from + 1)", value: $from, in: 0...last)
                        Stepper("To bar \(to + 1)", value: $to, in: from...last)
                    }
                } footer: {
                    Text("The section repeats until you turn the loop off. Pair it with a slower speed to work through a tricky passage.")
                }
            }
            .navigationTitle("Loop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        session.setLoop(enabled ? from...max(from, to) : nil)
                        dismiss()
                    }
                }
            }
            .onChange(of: from) { _, newValue in
                if to < newValue { to = newValue }
            }
        }
    }
}

// MARK: - Results

private struct ResultsOverlay: View {
    let result: SessionResult
    let onRetry: () -> Void
    let onClose: () -> Void

    private var headline: String {
        switch result.stars {
        case 3: return "Brilliant!"
        case 2: return "Great job!"
        case 1: return "Good start"
        default: return "Keep practising"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(headline).font(.title.bold())
                StarsView(stars: result.stars, size: 34)
                HStack(spacing: 28) {
                    stat("Accuracy", "\(Int((result.accuracy * 100).rounded()))%")
                    stat("Notes", "\(result.hits)/\(result.total)")
                    stat("Mistakes", "\(result.mistakes)")
                }
                HStack(spacing: 12) {
                    Button("Practise again", action: onRetry)
                        .buttonStyle(.bordered)
                    Button("Done", action: onClose)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding()
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
