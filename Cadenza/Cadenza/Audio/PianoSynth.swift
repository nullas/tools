import AVFoundation
import os

/// A tiny lock that the audio render thread can `tryLock` without blocking.
final class UnfairLock {
    private let pointer: os_unfair_lock_t

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    func lock() { os_unfair_lock_lock(pointer) }
    func unlock() { os_unfair_lock_unlock(pointer) }
    func tryLock() -> Bool { os_unfair_lock_trylock(pointer) }

    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

enum AudioSessionManager {
    /// `.playback` normally; `.playAndRecord` while the microphone listens for notes.
    static func configure(recording: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if recording {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            print("Audio session configuration failed: \(error)")
        }
    }
}

/// A small additive piano-like synthesizer.
///
/// Each voice sums eight slightly inharmonic partials read from a sine table. Higher
/// partials and higher notes decay faster, which gives a convincing struck-string tone
/// without shipping sample files. Commands from the main thread are queued and drained
/// by the render thread, which never blocks.
final class PianoSynth {
    static let shared = PianoSynth()

    private enum Command {
        case noteOn(pitch: Int, velocity: Float)
        case noteOff(pitch: Int)
        case click(accent: Bool)
        case allOff
    }

    private struct Voice {
        var active = false
        var pitch = 0
        var velocity: Float = 0
        var age = 0
        var released = false
        var releaseGain: Float = 1
        var phase = SIMD8<Float>(repeating: 0)
        var increment = SIMD8<Float>(repeating: 0)
        var level = SIMD8<Float>(repeating: 0)
        var decay = SIMD8<Float>(repeating: 1)
    }

    private struct Click {
        var remaining = 0
        var phase: Float = 0
        var increment: Float = 0
        var gain: Float = 0
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let lock = UnfairLock()
    private var pending: [Command] = []
    private var draining: [Command] = []

    // Render-thread state.
    private var voices = [Voice](repeating: Voice(), count: 24)
    private var click = Click()
    private var sampleRate: Float = 44_100
    private static let tableSize = 4096
    private var tableSize: Int { PianoSynth.tableSize }
    private let table: UnsafeMutablePointer<Float>
    private var releaseMultiplier: Float = 0.9995
    private var attackSamples = 100

    private init() {
        let size = PianoSynth.tableSize
        table = .allocate(capacity: size)
        for i in 0..<size {
            table[i] = sinf(2 * .pi * Float(i) / Float(size))
        }
        pending.reserveCapacity(64)
        draining.reserveCapacity(64)
        setUpEngine()

        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: .main) { [weak self] _ in
            self?.start()
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.start() }
        }
    }

    private func setUpEngine() {
        let hwRate = AVAudioSession.sharedInstance().sampleRate
        sampleRate = Float(hwRate > 0 ? hwRate : 44_100)
        releaseMultiplier = expf(-6.9 / (0.28 * sampleRate))
        attackSamples = Int(0.003 * sampleRate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else { return }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            self.render(frameCount: Int(frameCount), bufferList: bufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9
        sourceNode = node
    }

    // MARK: Public API (main thread)

    func start() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do { try engine.start() } catch { print("Synth failed to start: \(error)") }
    }

    func noteOn(_ pitch: Int, velocity: Float = 0.8) {
        enqueue(.noteOn(pitch: pitch, velocity: min(max(velocity, 0.05), 1)))
    }

    func noteOff(_ pitch: Int) { enqueue(.noteOff(pitch: pitch)) }
    func click(accent: Bool) { enqueue(.click(accent: accent)) }
    func allNotesOff() { enqueue(.allOff) }

    private func enqueue(_ command: Command) {
        if !engine.isRunning { start() }
        lock.withLock { pending.append(command) }
    }

    // MARK: Render thread

    private func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        if lock.tryLock() {
            swap(&pending, &draining)
            lock.unlock()
            for command in draining { apply(command) }
            draining.removeAll(keepingCapacity: true)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        for i in 0..<frameCount { out[i] = 0 }

        let tableScale = Float(tableSize)
        let mask = tableSize - 1
        for vi in voices.indices where voices[vi].active {
            var v = voices[vi]
            for i in 0..<frameCount {
                var sample: Float = 0
                for k in 0..<8 {
                    let amp = v.level[k]
                    if amp < 1e-5 { continue }
                    sample += table[Int(v.phase[k] * tableScale) & mask] * amp
                    var p = v.phase[k] + v.increment[k]
                    if p >= 1 { p -= 1 }
                    v.phase[k] = p
                }
                v.level *= v.decay
                let attack: Float = v.age < attackSamples ? Float(v.age) / Float(attackSamples) : 1
                if v.released { v.releaseGain *= releaseMultiplier }
                out[i] += sample * attack * v.releaseGain * v.velocity
                v.age += 1
            }
            if v.releaseGain < 1e-4 || v.level.max() < 1e-4 { v.active = false }
            voices[vi] = v
        }

        if click.remaining > 0 {
            let n = min(frameCount, click.remaining)
            for i in 0..<n {
                out[i] += table[Int(click.phase * tableScale) & mask] * click.gain
                click.phase += click.increment
                if click.phase >= 1 { click.phase -= 1 }
                click.gain *= 0.9975
            }
            click.remaining -= n
        }

        for i in 0..<frameCount { out[i] = tanhf(out[i] * 0.45) }
        for b in buffers.dropFirst() {
            b.mData?.assumingMemoryBound(to: Float.self).update(from: out, count: frameCount)
        }
    }

    private func apply(_ command: Command) {
        switch command {
        case let .noteOn(pitch, velocity):
            startVoice(pitch: pitch, velocity: velocity)
        case let .noteOff(pitch):
            for i in voices.indices where voices[i].active && voices[i].pitch == pitch && !voices[i].released {
                voices[i].released = true
            }
        case let .click(accent):
            click = Click(remaining: Int(0.04 * sampleRate), phase: 0,
                          increment: (accent ? 1_760 : 1_320) / sampleRate, gain: accent ? 0.5 : 0.32)
        case .allOff:
            for i in voices.indices where voices[i].active { voices[i].released = true }
        }
    }

    private func startVoice(pitch: Int, velocity: Float) {
        // Re-striking a key damps the previous string first.
        for i in voices.indices where voices[i].active && voices[i].pitch == pitch {
            voices[i].released = true
        }
        let slot = voices.firstIndex { !$0.active }
            ?? voices.indices.max { voices[$0].age < voices[$1].age } ?? 0

        let f0 = Float(MusicTheory.frequency(of: pitch))
        // Low strings ring for ~9 s, the top of the keyboard for well under a second.
        let sustain = max(0.6, 9.0 * powf(2, -Float(pitch - 33) / 22))
        let inharmonicity: Float = 0.00035
        let nyquist = sampleRate * 0.45

        var v = Voice()
        v.active = true
        v.pitch = pitch
        v.velocity = 0.18 + 0.32 * velocity
        for k in 0..<8 {
            let n = Float(k + 1)
            let f = f0 * n * sqrtf(1 + inharmonicity * n * n)
            v.increment[k] = f / sampleRate
            let brightness = 0.6 + 0.6 * velocity
            v.level[k] = f < nyquist ? powf(n, -1.6 / brightness) * (k == 0 ? 1 : 0.8) : 0
            let t60 = sustain / (1 + 0.55 * (n - 1))
            v.decay[k] = expf(-6.9 / (t60 * sampleRate))
        }
        voices[slot] = v
    }
}
