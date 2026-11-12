import Charts
import CoreAudioKit
import SwiftUI

struct ProfileView: View {
    @Environment(ProgressStore.self) private var progress
    @Environment(Library.self) private var library

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 0) {
                        stat("\(progress.streak())", "Day streak", "flame.fill", .orange)
                        stat("\(Int(progress.totalMinutes.rounded()))", "Minutes", "clock.fill", Theme.accent)
                        stat("\(progress.totalStars)", "Stars", "star.fill", .yellow)
                    }
                    .padding(.vertical, 6)
                }

                Section("This week") {
                    Chart {
                        ForEach(progress.recentDays()) { day in
                            BarMark(x: .value("Day", day.date, unit: .day),
                                    y: .value("Minutes", day.minutes))
                                .foregroundStyle(Theme.accent.gradient)
                                .cornerRadius(4)
                        }
                        RuleMark(y: .value("Goal", progress.dailyGoalMinutes))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        }
                    }
                    .frame(height: 160)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Practice minutes for the last seven days")
                }

                Section("Songs") {
                    let played = library.songs.filter { progress.record(for: $0.id) != nil }
                    if played.isEmpty {
                        Text("Songs you play will appear here with your best score.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(played) { song in
                            HStack {
                                SongCover(song: song, size: 36, cornerRadius: 8)
                                Text(song.title).lineLimit(1)
                                Spacer()
                                StarsView(stars: progress.record(for: song.id)?.stars ?? 0, size: 11)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }

    private func stat(_ value: String, _ label: String, _ symbol: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SettingsView: View {
    @Environment(InputManager.self) private var input
    @Environment(ProgressStore.self) private var progress
    @Environment(Library.self) private var library
    @State private var showBluetooth = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { input.micEnabled }, set: { input.setMicEnabled($0) })) {
                    Label("Listen with microphone", systemImage: "mic")
                }
                if input.micStatus == .denied {
                    Button("Allow microphone access in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("Acoustic piano")
            } footer: {
                Text("Place your phone on the music stand. Cadenza listens only for the notes the song expects, so a quiet room works best. Headphones stop the app's own sound from being heard as your playing.")
            }

            Section {
                if input.midiDevices.isEmpty {
                    Text("No MIDI devices connected").foregroundStyle(.secondary)
                } else {
                    ForEach(input.midiDevices, id: \.self) { name in
                        Label(name, systemImage: "pianokeys")
                    }
                }
                Button {
                    showBluetooth = true
                } label: {
                    Label("Connect a Bluetooth MIDI keyboard", systemImage: "dot.radiowaves.left.and.right")
                }
                Toggle(isOn: Binding(get: { input.midiSoundEnabled }, set: { input.setMIDISoundEnabled($0) })) {
                    Label("Play sound for MIDI notes", systemImage: "speaker.wave.2")
                }
            } header: {
                Text("Digital piano")
            } footer: {
                Text("Plug in a USB MIDI keyboard with a Lightning or USB‑C adapter, or pair one over Bluetooth. Turn on sound if your keyboard has no speakers.")
            }

            Section("Display") {
                Toggle(isOn: Binding(get: { input.showNoteNames }, set: { input.setShowNoteNames($0) })) {
                    Label("Show note names", systemImage: "textformat.abc")
                }
            }

            Section("Goal") {
                Stepper(value: Binding(get: { progress.dailyGoalMinutes }, set: { progress.setDailyGoal(minutes: $0) }),
                        in: 5...120, step: 5) {
                    Label("Daily goal: \(progress.dailyGoalMinutes) min", systemImage: "target")
                }
            }

            Section {
                Button("Reset progress", role: .destructive) { confirmReset = true }
            }

            if !library.loadErrors.isEmpty {
                Section("Content problems") {
                    ForEach(library.loadErrors, id: \.self) { Text($0).font(.footnote.monospaced()) }
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showBluetooth, onDismiss: { input.refreshMIDIDevices() }) {
            BluetoothMIDIView().ignoresSafeArea()
        }
        .confirmationDialog("Reset all progress?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { progress.reset() }
        } message: {
            Text("Stars, scores and practice history will be deleted.")
        }
    }
}

/// Apple's built-in screen for finding and pairing Bluetooth LE MIDI devices.
struct BluetoothMIDIView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = CABTMIDICentralViewController()
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak controller] _ in controller?.dismiss(animated: true) }
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
