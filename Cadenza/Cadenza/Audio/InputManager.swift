import AVFoundation
import Foundation
import Observation

/// Collects notes from the on-screen keyboard, MIDI devices and the microphone,
/// sounds them where appropriate, and forwards them to the current `NoteReceiver`.
@Observable
final class InputManager {
    enum MicStatus: Equatable {
        case off, requesting, listening, denied
        case failed(String)
    }

    private(set) var midiDevices: [String] = []
    private(set) var micStatus: MicStatus = .off
    private(set) var micLevel: Float = 0
    private(set) var lastSource: InputSource?

    /// Listen through the microphone while a song is open.
    private(set) var micEnabled: Bool
    /// Sound the built-in piano for MIDI notes (off for digital pianos with their own speakers).
    private(set) var midiSoundEnabled: Bool
    /// Show note names on keys and notes.
    private(set) var showNoteNames: Bool

    @ObservationIgnored weak var receiver: NoteReceiver?
    @ObservationIgnored private let midi = MIDIInput()
    @ObservationIgnored private let mic = MicNoteDetector()
    @ObservationIgnored private let synth = PianoSynth.shared
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listeningRequested = false
    @ObservationIgnored private var micReleases: [Int: DispatchWorkItem] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        micEnabled = defaults.bool(forKey: "input.mic")
        midiSoundEnabled = defaults.object(forKey: "input.midiSound") as? Bool ?? false
        showNoteNames = defaults.object(forKey: "display.noteNames") as? Bool ?? true

        midi.onDevicesChanged = { [weak self] names in self?.midiDevices = names }
        midi.onNoteOn = { [weak self] pitch, velocity in
            guard let self else { return }
            self.lastSource = .midi
            if self.midiSoundEnabled { self.synth.noteOn(pitch, velocity: Float(velocity) / 127) }
            self.receiver?.noteOn(pitch, velocity: velocity, source: .midi)
        }
        midi.onNoteOff = { [weak self] pitch in
            guard let self else { return }
            if self.midiSoundEnabled { self.synth.noteOff(pitch) }
            self.receiver?.noteOff(pitch, source: .midi)
        }
        mic.onLevel = { [weak self] level in self?.micLevel = level }
        mic.onNote = { [weak self] pitch in self?.micHeard(pitch) }
    }

    func start() {
        AudioSessionManager.configure(recording: false)
        synth.start()
        midi.start()
    }

    // MARK: Settings

    func setMicEnabled(_ enabled: Bool) {
        micEnabled = enabled
        defaults.set(enabled, forKey: "input.mic")
        if listeningRequested {
            enabled ? startMic() : stopMic()
        }
    }

    func setMIDISoundEnabled(_ enabled: Bool) {
        midiSoundEnabled = enabled
        defaults.set(enabled, forKey: "input.midiSound")
    }

    func setShowNoteNames(_ enabled: Bool) {
        showNoteNames = enabled
        defaults.set(enabled, forKey: "display.noteNames")
    }

    func refreshMIDIDevices() { midi.connectSources() }

    // MARK: Listening lifecycle (called by the player)

    func beginListening() {
        listeningRequested = true
        if micEnabled { startMic() }
    }

    func endListening() {
        listeningRequested = false
        stopMic()
    }

    func setExpectedNotes(_ pitches: Set<Int>) {
        mic.setCandidates(pitches)
    }

    // MARK: On-screen keyboard

    func touchDown(_ pitch: Int) {
        lastSource = .touch
        synth.noteOn(pitch, velocity: 0.75)
        receiver?.noteOn(pitch, velocity: 96, source: .touch)
    }

    func touchUp(_ pitch: Int) {
        synth.noteOff(pitch)
        receiver?.noteOff(pitch, source: .touch)
    }

    // MARK: Microphone

    private func startMic() {
        guard !mic.isRunning else { return }
        micStatus = .requesting
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.listeningRequested, self.micEnabled else {
                    self.micStatus = .off
                    return
                }
                guard granted else {
                    self.micStatus = .denied
                    return
                }
                AudioSessionManager.configure(recording: true)
                do {
                    try self.mic.start()
                    self.micStatus = .listening
                } catch {
                    self.micStatus = .failed(error.localizedDescription)
                    AudioSessionManager.configure(recording: false)
                }
            }
        }
    }

    private func stopMic() {
        let wasRunning = mic.isRunning
        mic.stop()
        micLevel = 0
        if micStatus != .denied { micStatus = .off }
        if wasRunning { AudioSessionManager.configure(recording: false) }
    }

    private func micHeard(_ pitch: Int) {
        lastSource = .microphone
        micReleases[pitch]?.cancel()
        receiver?.noteOn(pitch, velocity: 80, source: .microphone)
        // A microphone cannot tell when a key is released; light the key briefly.
        let release = DispatchWorkItem { [weak self] in
            self?.receiver?.noteOff(pitch, source: .microphone)
            self?.micReleases[pitch] = nil
        }
        micReleases[pitch] = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: release)
    }
}
