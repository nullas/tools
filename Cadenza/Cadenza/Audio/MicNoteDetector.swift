import Accelerate
import AVFoundation

/// Hears an acoustic piano through the microphone.
///
/// Recognising arbitrary chords from audio is hard, but a practice app always knows which
/// notes it is waiting for. The detector therefore only answers one question: "is each
/// expected note sounding, and did it just start?" For every candidate pitch it measures the
/// energy at the fundamental and first harmonics in a 4096-point spectrum, compares it with the
/// noise floor and with the neighbouring semitones, and reports the note when that energy is
/// present and rising (a fresh key strike rather than a string that is still ringing).
final class MicNoteDetector {
    /// Called on the main thread when an expected note is struck.
    var onNote: ((Int) -> Void)?
    /// Input level (RMS, 0…1), on the main thread, about 20 times a second.
    var onLevel: ((Float) -> Void)?

    // Tuning constants. Raise `presenceRatio` if the app hears notes you did not play.
    var presenceRatio: Float = 6
    var risingRatio: Float = 1.25
    var neighbourRatio: Float = 1.1
    var minimumRMS: Float = 0.002
    var refractory: TimeInterval = 0.12

    private let engine = AVAudioEngine()
    private let lock = UnfairLock()
    private var candidates: Set<Int> = []
    private(set) var isRunning = false

    private let fftSize = 4096
    private let hopSize = 1024
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var samples: [Float] = []
    private var magnitudes: [Float]
    private var previousMagnitudes: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var sampleRate: Float = 44_100
    private var lastFired: [Int: TimeInterval] = [:]
    private var frameTime: TimeInterval = 0
    private var levelCounter = 0

    init() {
        fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 4096, isHalfWindow: false)
        magnitudes = [Float](repeating: 0, count: 2048)
        previousMagnitudes = magnitudes
        real = magnitudes
        imag = magnitudes
    }

    /// The notes the detector should listen for. Safe to call from any thread.
    func setCandidates(_ pitches: Set<Int>) {
        lock.withLock { candidates = pitches }
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Cadenza", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        sampleRate = Float(format.sampleRate)
        samples.removeAll(keepingCapacity: true)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    // MARK: Analysis (audio tap thread)

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        while samples.count >= fftSize {
            analyze(Array(samples[0..<fftSize]))
            samples.removeFirst(hopSize)
            frameTime += Double(hopSize) / Double(sampleRate)
        }
    }

    private func analyze(_ frame: [Float]) {
        let rms = vDSP.rootMeanSquare(frame)
        levelCounter += 1
        if levelCounter % 2 == 0 {
            DispatchQueue.main.async { [weak self] in self?.onLevel?(min(1, rms * 8)) }
        }

        swap(&magnitudes, &previousMagnitudes)
        let windowed = vDSP.multiply(frame, window)
        let half = fftSize / 2
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                let source = split
                fft.forward(input: source, output: &split)
                magnitudes.withUnsafeMutableBufferPointer { mags in
                    vDSP_zvabs(&split, 1, mags.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        let pitches = lock.withLock { candidates }
        guard !pitches.isEmpty, rms > minimumRMS else { return }

        let binHz = sampleRate / Float(fftSize)
        let floorBins = magnitudes[3..<min(half, Int(4_000 / binHz))].sorted()
        let noise = max(floorBins[floorBins.count / 2], 1e-6)

        var detected: [Int] = []
        for pitch in pitches {
            let now = salience(pitch, in: magnitudes, binHz: binHz)
            guard now > noise * presenceRatio else { continue }
            let before = salience(pitch, in: previousMagnitudes, binHz: binHz)
            guard now > before * risingRatio else { continue }
            // Neighbouring semitones are only resolvable above roughly 150 Hz with this window.
            if MusicTheory.frequency(of: pitch) > 150 {
                let neighbour = max(salience(pitch - 1, in: magnitudes, binHz: binHz),
                                    salience(pitch + 1, in: magnitudes, binHz: binHz))
                guard now > neighbour * neighbourRatio else { continue }
            }
            if let last = lastFired[pitch], frameTime - last < refractory { continue }
            lastFired[pitch] = frameTime
            detected.append(pitch)
        }

        if !detected.isEmpty {
            DispatchQueue.main.async { [weak self] in
                detected.forEach { self?.onNote?($0) }
            }
        }
    }

    /// Weighted sum of the spectral peaks at the first five harmonics of `pitch`.
    private func salience(_ pitch: Int, in mags: [Float], binHz: Float) -> Float {
        let f0 = Float(MusicTheory.frequency(of: pitch))
        let weights: [Float] = [1, 0.8, 0.6, 0.45, 0.35]
        var total: Float = 0
        for (index, weight) in weights.enumerated() {
            let bin = f0 * Float(index + 1) / binHz
            let low = max(1, Int(bin * 0.985))
            let high = min(mags.count - 1, Int((bin * 1.015).rounded(.up)))
            guard low <= high else { break }
            var peak: Float = 0
            for b in low...high { peak = max(peak, mags[b]) }
            total += peak * weight
        }
        return total
    }
}
