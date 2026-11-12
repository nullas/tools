import SwiftUI
import UIKit

/// Geometry of a piano keyboard spanning `low…high` in a given size. Shared by the keyboard
/// and the falling-notes view so notes line up exactly with their keys.
struct KeyboardLayout {
    let low: Int
    let high: Int
    let size: CGSize
    let whiteKeys: [Int]
    private let whiteIndex: [Int: Int]

    init(low: Int, high: Int, size: CGSize) {
        self.low = low
        self.high = max(high, low)
        self.size = size
        whiteKeys = (low...max(high, low)).filter { !MusicTheory.isBlack($0) }
        var index: [Int: Int] = [:]
        var count = 0
        for p in low...max(high, low) {
            index[p] = count
            if !MusicTheory.isBlack(p) { count += 1 }
        }
        whiteIndex = index
    }

    var whiteWidth: CGFloat { size.width / CGFloat(max(whiteKeys.count, 1)) }
    var blackWidth: CGFloat { whiteWidth * 0.6 }
    var blackHeight: CGFloat { size.height * 0.62 }

    func contains(_ pitch: Int) -> Bool { pitch >= low && pitch <= high }

    /// Frame of a key. For a black key, its index is the white key to its right.
    func frame(for pitch: Int) -> CGRect {
        let index = CGFloat(whiteIndex[pitch] ?? 0)
        if MusicTheory.isBlack(pitch) {
            return CGRect(x: index * whiteWidth - blackWidth / 2, y: 0, width: blackWidth, height: blackHeight)
        }
        return CGRect(x: index * whiteWidth, y: 0, width: whiteWidth, height: size.height)
    }

    func pitch(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.x <= size.width, point.y >= 0, point.y <= size.height else { return nil }
        if point.y <= blackHeight {
            for p in low...high where MusicTheory.isBlack(p) && frame(for: p).contains(point) {
                return p
            }
        }
        let i = min(whiteKeys.count - 1, max(0, Int(point.x / whiteWidth)))
        return whiteKeys.isEmpty ? nil : whiteKeys[i]
    }

    /// A keyboard range that shows every note in the song with a little room around it:
    /// whole octaves, C to B, at least two octaves wide.
    static func range(for song: Song) -> (low: Int, high: Int) {
        var low = song.pitchRange.lowerBound - 2
        var high = song.pitchRange.upperBound + 2
        low -= ((low % 12) + 12) % 12
        high += 11 - ((high % 12) + 12) % 12
        while high - low + 1 < 24 {
            if low > 36 { low -= 12 }
            if high - low + 1 < 24 { high += 12 }
        }
        return (max(12, low), min(119, high))
    }
}

struct KeyboardView: View {
    let low: Int
    let high: Int
    /// Keys to light up and the colour to use (expected notes, accompaniment).
    let highlights: [Int: Color]
    let pressed: Set<Int>
    let wrong: Set<Int>
    let showLabels: Bool
    let onDown: (Int) -> Void
    let onUp: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let layout = KeyboardLayout(low: low, high: high, size: geo.size)
            Canvas { context, _ in
                draw(in: &context, layout: layout)
            }
            .overlay(
                MultiTouchSurface(pitchAt: { layout.pitch(at: $0) }, onDown: onDown, onUp: onUp)
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Piano keyboard")
    }

    private func fill(for pitch: Int, black: Bool) -> Color {
        if wrong.contains(pitch) { return Theme.miss }
        if let color = highlights[pitch] {
            return pressed.contains(pitch) ? Theme.hit : color
        }
        if pressed.contains(pitch) { return black ? Color(white: 0.4) : Color(white: 0.78) }
        return black ? Color(white: 0.1) : .white
    }

    private func draw(in context: inout GraphicsContext, layout: KeyboardLayout) {
        let radius = max(2, layout.whiteWidth * 0.12)
        context.fill(Path(CGRect(origin: .zero, size: layout.size)), with: .color(.black))

        for pitch in layout.whiteKeys {
            let rect = layout.frame(for: pitch).insetBy(dx: 0.75, dy: 0)
            let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                .path(in: rect)
            context.fill(shape, with: .color(fill(for: pitch, black: false)))

            let isC = pitch % 12 == 0
            if showLabels || isC {
                let text = isC ? MusicTheory.name(of: pitch) : MusicTheory.sharpNames[pitch % 12]
                let label = Text(text)
                    .font(.system(size: min(11, layout.whiteWidth * 0.42), weight: isC ? .semibold : .regular))
                    .foregroundColor(Color(white: 0.45))
                context.draw(label, at: CGPoint(x: rect.midX, y: rect.maxY - min(14, rect.height * 0.1)))
            }
        }

        for pitch in layout.low...layout.high where MusicTheory.isBlack(pitch) {
            let rect = layout.frame(for: pitch)
            let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius * 0.7, bottomTrailingRadius: radius * 0.7)
                .path(in: rect)
            context.fill(shape, with: .color(fill(for: pitch, black: true)))
            // A soft highlight so black keys read as raised.
            let shine = CGRect(x: rect.minX + rect.width * 0.18, y: rect.minY, width: rect.width * 0.64, height: rect.height * 0.92)
            context.fill(Path(roundedRect: shine, cornerRadius: radius * 0.5), with: .color(.white.opacity(0.06)))
        }

        // Felt strip along the top of the keys.
        context.fill(Path(CGRect(x: 0, y: 0, width: layout.size.width, height: 3)),
                     with: .color(Color(red: 0.55, green: 0.1, blue: 0.12)))
    }
}

/// Transparent multi-touch layer: each finger presses the key under it and can glide across keys.
struct MultiTouchSurface: UIViewRepresentable {
    let pitchAt: (CGPoint) -> Int?
    let onDown: (Int) -> Void
    let onUp: (Int) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.pitchAt = pitchAt
        view.onDown = onDown
        view.onUp = onUp
    }

    final class TouchView: UIView {
        var pitchAt: ((CGPoint) -> Int?)?
        var onDown: ((Int) -> Void)?
        var onUp: ((Int) -> Void)?
        private var active: [UITouch: Int] = [:]

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                guard let pitch = pitchAt?(touch.location(in: self)) else { continue }
                active[touch] = pitch
                onDown?(pitch)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                let pitch = pitchAt?(touch.location(in: self))
                guard pitch != active[touch] else { continue }
                if let old = active[touch] { onUp?(old) }
                active[touch] = pitch
                if let pitch { onDown?(pitch) }
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

        private func release(_ touches: Set<UITouch>) {
            for touch in touches {
                if let pitch = active.removeValue(forKey: touch) { onUp?(pitch) }
            }
        }
    }
}
