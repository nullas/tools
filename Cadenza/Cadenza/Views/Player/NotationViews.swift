import SwiftUI

/// An immutable picture of the session for one frame. Built in `PlayerView.body` so that
/// SwiftUI's observation tracking sees every value the canvases draw from.
struct NotationSnapshot {
    let song: Song
    let playhead: Double
    let states: [Int: NoteState]
    let expectedIDs: Set<Int>
    let hands: HandSelection
    let mode: PlayMode
    let loop: ClosedRange<Int>?
    let showNames: Bool

    func isActive(_ note: NoteEvent) -> Bool {
        mode == .listen || hands.includes(note.hand)
    }

    func color(for note: NoteEvent, idle: Color) -> Color {
        if let state = states[note.id] {
            if mode == .listen { return Theme.color(for: note.hand) }
            return state == .hit ? Theme.hit : Theme.miss
        }
        if !isActive(note) { return idle.opacity(0.3) }
        if expectedIDs.contains(note.id) { return Theme.color(for: note.hand) }
        return idle
    }
}

/// Lets the player drag the music left and right while paused.
private struct ScrubModifier: ViewModifier {
    let enabled: Bool
    let playhead: Double
    /// Points of drag per beat, signed for the drag direction.
    let pointsPerBeat: CGFloat
    let axis: Axis
    let onSeek: (Double) -> Void
    @State private var startBeat: Double?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    guard enabled else { return }
                    if startBeat == nil { startBeat = playhead }
                    let delta = axis == .horizontal ? value.translation.width : value.translation.height
                    onSeek((startBeat ?? playhead) - Double(delta / pointsPerBeat))
                }
                .onEnded { _ in startBeat = nil },
            including: enabled ? .all : .subviews
        )
    }
}

// MARK: - Sheet music

struct SheetGeometry {
    let size: CGSize
    let song: Song

    var lineSpacing: CGFloat { min(max(size.height / 20, 5), 15) }
    var halfStep: CGFloat { lineSpacing / 2 }
    var centerY: CGFloat { size.height / 2 }
    /// The E4 line, bottom of the treble staff.
    var trebleBottom: CGFloat { centerY - 1.5 * lineSpacing }
    /// The A3 line, top of the bass staff.
    var bassTop: CGFloat { centerY + 1.5 * lineSpacing }
    var gutter: CGFloat { lineSpacing * 6 }
    var playheadX: CGFloat { max(gutter + lineSpacing * 3, size.width * 0.28) }
    var pixelsPerBeat: CGFloat { lineSpacing * 8.5 * 4 / CGFloat(song.beatUnit) }

    func y(step: Int, hand: Hand) -> CGFloat {
        hand == .right
            ? trebleBottom - CGFloat(step - 30) * halfStep
            : bassTop - CGFloat(step - 26) * halfStep
    }

    func x(beat: Double, playhead: Double) -> CGFloat {
        playheadX + CGFloat(beat - playhead) * pixelsPerBeat
    }

    /// Lowest and highest line of each staff, as staff steps.
    static func lines(for hand: Hand) -> (bottom: Int, top: Int) {
        hand == .right ? (30, 38) : (18, 26)
    }
}

struct SheetMusicView: View {
    let snapshot: NotationSnapshot
    let canScrub: Bool
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let geometry = SheetGeometry(size: geo.size, song: snapshot.song)
            Canvas { context, _ in
                SheetRenderer(snapshot: snapshot, g: geometry).draw(in: &context)
            }
            .modifier(ScrubModifier(enabled: canScrub, playhead: snapshot.playhead,
                                    pointsPerBeat: geometry.pixelsPerBeat, axis: .horizontal, onSeek: onSeek))
        }
        .background(Theme.paper)
        .accessibilityLabel("Sheet music")
    }
}

private struct SheetRenderer {
    let snapshot: NotationSnapshot
    let g: SheetGeometry

    private var ink: Color { Theme.ink }
    private var ls: CGFloat { g.lineSpacing }

    func draw(in ctx: inout GraphicsContext) {
        drawLoop(&ctx)
        drawStaves(&ctx)
        drawBarLines(&ctx)
        drawNotes(&ctx)
        drawGutter(&ctx)
        drawPlayhead(&ctx)
    }

    private func line(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, width: CGFloat, color: Color) {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        ctx.stroke(path, with: .color(color), lineWidth: width)
    }

    private func drawLoop(_ ctx: inout GraphicsContext) {
        guard let loop = snapshot.loop else { return }
        let x0 = g.x(beat: snapshot.song.barStart(loop.lowerBound), playhead: snapshot.playhead)
        let x1 = g.x(beat: snapshot.song.barEnd(loop.upperBound), playhead: snapshot.playhead)
        let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: g.size.height)
        ctx.fill(Path(rect), with: .color(Theme.accent.opacity(0.08)))
        for x in [x0, x1] {
            line(&ctx, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: g.size.height), width: 2, color: Theme.accent.opacity(0.6))
        }
    }

    private func drawStaves(_ ctx: inout GraphicsContext) {
        for hand in [Hand.right, .left] {
            let (bottom, top) = SheetGeometry.lines(for: hand)
            for step in stride(from: bottom, through: top, by: 2) {
                let y = g.y(step: step, hand: hand)
                line(&ctx, from: CGPoint(x: 0, y: y), to: CGPoint(x: g.size.width, y: y),
                     width: max(0.8, ls * 0.08), color: ink.opacity(0.55))
            }
        }
    }

    private var systemTop: CGFloat { g.y(step: 38, hand: .right) }
    private var systemBottom: CGFloat { g.y(step: 18, hand: .left) }

    private func drawBarLines(_ ctx: inout GraphicsContext) {
        let song = snapshot.song
        for (index, beat) in song.barStarts.enumerated() {
            let x = g.x(beat: beat, playhead: snapshot.playhead)
            guard x > g.gutter - ls, x < g.size.width + ls else { continue }
            if index > 0 {
                line(&ctx, from: CGPoint(x: x, y: systemTop), to: CGPoint(x: x, y: systemBottom),
                     width: max(1, ls * 0.1), color: ink.opacity(0.6))
            }
            ctx.draw(Text("\(index + 1)").font(.system(size: ls * 0.95)).foregroundColor(ink.opacity(0.45)),
                     at: CGPoint(x: x + ls * 0.4, y: systemTop - ls * 1.4), anchor: .leading)
        }
        // Final double bar.
        let end = g.x(beat: song.totalBeats, playhead: snapshot.playhead)
        if end < g.size.width + ls {
            line(&ctx, from: CGPoint(x: end - ls * 0.5, y: systemTop), to: CGPoint(x: end - ls * 0.5, y: systemBottom),
                 width: max(1, ls * 0.1), color: ink)
            line(&ctx, from: CGPoint(x: end, y: systemTop), to: CGPoint(x: end, y: systemBottom),
                 width: ls * 0.4, color: ink)
        }
    }

    private struct Chord {
        let hand: Hand
        let start: Double
        let quarters: Double
        var notes: [NoteEvent]
    }

    private func drawNotes(_ ctx: inout GraphicsContext) {
        let song = snapshot.song
        let minBeat = snapshot.playhead - Double((g.playheadX + ls * 4) / g.pixelsPerBeat)
        let maxBeat = snapshot.playhead + Double((g.size.width - g.playheadX + ls * 4) / g.pixelsPerBeat)

        var chords: [Chord] = []
        for note in song.notes where note.start <= maxBeat && note.start >= minBeat {
            let q = song.quarterLength(of: note)
            if let i = chords.lastIndex(where: { $0.hand == note.hand && abs($0.start - note.start) < 1e-6 && abs($0.quarters - q) < 1e-6 }) {
                chords[i].notes.append(note)
            } else {
                chords.append(Chord(hand: note.hand, start: note.start, quarters: q, notes: [note]))
            }
        }
        for chord in chords { drawChord(chord, in: &ctx) }
    }

    private func drawChord(_ chord: Chord, in ctx: inout GraphicsContext) {
        let x = g.x(beat: chord.start, playhead: snapshot.playhead)
        let (bottom, top) = SheetGeometry.lines(for: chord.hand)
        let middle = (bottom + top) / 2
        let headW = ls * 1.32
        let headH = ls * 0.98
        let q = chord.quarters
        let filled = q < 2 - 1e-6
        let hasStem = q < 4 - 1e-6
        let flags = q <= 0.25 + 1e-6 ? 2 : (q <= 0.5 + 1e-6 ? 1 : 0)
        let dotted = [0.75, 1.5, 3.0].contains { abs($0 - q) < 1e-6 }
        let steps = chord.notes.map(\.staffStep)
        let average = Double(steps.reduce(0, +)) / Double(steps.count)
        let stemUp = average < Double(middle)
        let stemColor = snapshot.color(for: chord.notes[0], idle: ink)

        for note in chord.notes {
            let y = g.y(step: note.staffStep, hand: chord.hand)
            let color = snapshot.color(for: note, idle: ink)

            // Ledger lines.
            let ledgerSteps: [Int]
            if note.staffStep < bottom {
                ledgerSteps = Array(stride(from: bottom - 2, through: note.staffStep, by: -2))
            } else if note.staffStep > top {
                ledgerSteps = Array(stride(from: top + 2, through: note.staffStep, by: 2))
            } else {
                ledgerSteps = []
            }
            for step in ledgerSteps {
                let ly = g.y(step: step, hand: chord.hand)
                line(&ctx, from: CGPoint(x: x - headW * 0.85, y: ly), to: CGPoint(x: x + headW * 0.85, y: ly),
                     width: max(0.8, ls * 0.1), color: ink.opacity(0.7))
            }

            if snapshot.expectedIDs.contains(note.id) && snapshot.states[note.id] == nil {
                ctx.fill(Path(ellipseIn: CGRect(x: x - ls * 1.3, y: y - ls * 1.3, width: ls * 2.6, height: ls * 2.6)),
                         with: .color(Theme.color(for: note.hand).opacity(0.22)))
            }

            var head = Path(ellipseIn: CGRect(x: -headW / 2, y: -headH / 2, width: headW, height: headH))
            head = head.applying(CGAffineTransform(rotationAngle: -0.35))
                .applying(CGAffineTransform(translationX: x, y: y))
            if filled {
                ctx.fill(head, with: .color(color))
            } else {
                ctx.stroke(head, with: .color(color), lineWidth: max(1.2, ls * 0.2))
            }

            if note.accidental != 0 {
                let symbol = note.accidental > 0 ? "♯" : "♭"
                ctx.draw(Text(symbol).font(.system(size: ls * 1.9)).foregroundColor(color),
                         at: CGPoint(x: x - headW * 1.25, y: y), anchor: .center)
            }

            if dotted {
                let onLine = (note.staffStep - bottom) % 2 == 0
                let dy = onLine ? -halfStepOffset : 0
                let r = ls * 0.17
                ctx.fill(Path(ellipseIn: CGRect(x: x + headW * 0.85 - r, y: y + dy - r, width: 2 * r, height: 2 * r)),
                         with: .color(color))
            }

            if snapshot.showNames {
                let name = MusicTheory.letterName(staffStep: note.staffStep, accidental: note.accidental)
                ctx.draw(Text(name).font(.system(size: ls * 0.95, weight: .semibold)).foregroundColor(color),
                         at: CGPoint(x: x, y: stemUp ? y + ls * 1.45 : y - ls * 1.45), anchor: .center)
            }
        }

        guard hasStem else { return }
        let ys = chord.notes.map { g.y(step: $0.staffStep, hand: chord.hand) }
        let stemLength = ls * 3.3
        let stemWidth = max(1, ls * 0.11)
        if stemUp {
            let sx = x + headW / 2 - stemWidth / 2
            let tip = (ys.min() ?? 0) - stemLength
            line(&ctx, from: CGPoint(x: sx, y: ys.max() ?? 0), to: CGPoint(x: sx, y: tip), width: stemWidth, color: stemColor)
            drawFlags(flags, x: sx, tip: tip, direction: 1, color: stemColor, in: &ctx)
        } else {
            let sx = x - headW / 2 + stemWidth / 2
            let tip = (ys.max() ?? 0) + stemLength
            line(&ctx, from: CGPoint(x: sx, y: ys.min() ?? 0), to: CGPoint(x: sx, y: tip), width: stemWidth, color: stemColor)
            drawFlags(flags, x: sx, tip: tip, direction: -1, color: stemColor, in: &ctx)
        }
    }

    private var halfStepOffset: CGFloat { g.halfStep }

    /// `direction` is 1 for an up stem (flags hang down from the tip), -1 for a down stem.
    private func drawFlags(_ count: Int, x: CGFloat, tip: CGFloat, direction: CGFloat, color: Color,
                           in ctx: inout GraphicsContext) {
        for i in 0..<count {
            let y0 = tip + direction * CGFloat(i) * ls * 0.8
            var path = Path()
            path.move(to: CGPoint(x: x, y: y0))
            path.addQuadCurve(to: CGPoint(x: x + ls * 0.95, y: y0 + direction * ls * 1.9),
                              control: CGPoint(x: x + ls * 0.15, y: y0 + direction * ls * 1.0))
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: ls * 0.24, lineCap: .round))
        }
    }

    private func drawGutter(_ ctx: inout GraphicsContext) {
        let fadeWidth = ls * 2.5
        ctx.fill(Path(CGRect(x: 0, y: 0, width: g.gutter, height: g.size.height)), with: .color(Theme.paper))
        ctx.fill(Path(CGRect(x: g.gutter, y: 0, width: fadeWidth, height: g.size.height)),
                 with: .linearGradient(Gradient(colors: [Theme.paper, Theme.paper.opacity(0)]),
                                       startPoint: CGPoint(x: g.gutter, y: 0),
                                       endPoint: CGPoint(x: g.gutter + fadeWidth, y: 0)))

        // Staff lines continue through the gutter.
        for hand in [Hand.right, .left] {
            let (bottom, top) = SheetGeometry.lines(for: hand)
            for step in stride(from: bottom, through: top, by: 2) {
                let y = g.y(step: step, hand: hand)
                line(&ctx, from: CGPoint(x: ls * 0.6, y: y), to: CGPoint(x: g.gutter + fadeWidth, y: y),
                     width: max(0.8, ls * 0.08), color: ink.opacity(0.55))
            }
        }
        // System line.
        line(&ctx, from: CGPoint(x: ls * 0.6, y: systemTop), to: CGPoint(x: ls * 0.6, y: systemBottom),
             width: max(1.5, ls * 0.18), color: ink)

        let clefX = ls * 2.3
        ctx.draw(Text("𝄞").font(.system(size: ls * 6.2)).foregroundColor(ink),
                 at: CGPoint(x: clefX, y: g.y(step: 33, hand: .right)), anchor: .center)
        ctx.draw(Text("𝄢").font(.system(size: ls * 3.6)).foregroundColor(ink),
                 at: CGPoint(x: clefX, y: g.y(step: 23, hand: .left)), anchor: .center)

        let song = snapshot.song
        let timeX = ls * 4.6
        for hand in [Hand.right, .left] {
            let (bottom, top) = SheetGeometry.lines(for: hand)
            let font = Font.system(size: ls * 2.1, weight: .heavy, design: .serif)
            ctx.draw(Text("\(song.beatsPerBar)").font(font).foregroundColor(ink),
                     at: CGPoint(x: timeX, y: g.y(step: top - 2, hand: hand)), anchor: .center)
            ctx.draw(Text("\(song.beatUnit)").font(font).foregroundColor(ink),
                     at: CGPoint(x: timeX, y: g.y(step: bottom + 2, hand: hand)), anchor: .center)
        }
    }

    private func drawPlayhead(_ ctx: inout GraphicsContext) {
        let x = g.playheadX
        let band = CGRect(x: x - ls * 0.9, y: systemTop - ls * 2, width: ls * 1.8, height: systemBottom - systemTop + ls * 4)
        ctx.fill(Path(roundedRect: band, cornerRadius: ls * 0.9), with: .color(Theme.accent.opacity(0.12)))
        line(&ctx, from: CGPoint(x: x, y: band.minY), to: CGPoint(x: x, y: band.maxY), width: 2, color: Theme.accent)
    }
}

// MARK: - Falling notes

struct WaterfallView: View {
    let snapshot: NotationSnapshot
    let low: Int
    let high: Int
    let canScrub: Bool
    let onSeek: (Double) -> Void

    static func pixelsPerBeat(height: CGFloat, song: Song) -> CGFloat {
        height / (CGFloat(song.beatsPerBar) * 1.6)
    }

    var body: some View {
        GeometryReader { geo in
            let ppb = WaterfallView.pixelsPerBeat(height: geo.size.height, song: snapshot.song)
            Canvas { context, size in
                draw(in: &context, size: size, ppb: ppb)
            }
            .modifier(ScrubModifier(enabled: canScrub, playhead: snapshot.playhead,
                                    pointsPerBeat: -ppb, axis: .vertical, onSeek: onSeek))
        }
        .background(Theme.stage)
        .accessibilityLabel("Falling notes")
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, ppb: CGFloat) {
        let song = snapshot.song
        let layout = KeyboardLayout(low: low, high: high, size: size)
        let playhead = snapshot.playhead
        func y(_ beat: Double) -> CGFloat { size.height - CGFloat(beat - playhead) * ppb }

        if let loop = snapshot.loop {
            let top = y(song.barEnd(loop.upperBound))
            let bottom = y(song.barStart(loop.lowerBound))
            ctx.fill(Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)),
                     with: .color(Theme.accent.opacity(0.08)))
        }

        // Octave guides at every C and F.
        for pitch in layout.whiteKeys where pitch % 12 == 0 || pitch % 12 == 5 {
            let x = layout.frame(for: pitch).minX
            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                     with: .color(.white.opacity(pitch % 12 == 0 ? 0.1 : 0.04)))
        }

        for (index, beat) in song.barStarts.enumerated() {
            let by = y(beat)
            guard by > -10, by < size.height + 10 else { continue }
            ctx.fill(Path(CGRect(x: 0, y: by, width: size.width, height: 1)), with: .color(.white.opacity(0.12)))
            ctx.draw(Text("\(index + 1)").font(.caption2).foregroundColor(.white.opacity(0.35)),
                     at: CGPoint(x: 6, y: by - 8), anchor: .leading)
        }

        for note in song.notes where layout.contains(note.pitch) {
            let bottom = y(note.start)
            let top = y(note.end)
            guard bottom > 0, top < size.height else { continue }
            var rect = layout.frame(for: note.pitch)
            rect = rect.insetBy(dx: MusicTheory.isBlack(note.pitch) ? 1 : rect.width * 0.12, dy: 0)
            rect.origin.y = top + 1
            rect.size.height = max(4, bottom - top - 2)

            let color = snapshot.color(for: note, idle: Theme.color(for: note.hand).opacity(0.85))
            let shape = Path(roundedRect: rect, cornerRadius: min(6, rect.width * 0.3))
            ctx.fill(shape, with: .color(color))
            if snapshot.expectedIDs.contains(note.id), snapshot.states[note.id] == nil {
                ctx.stroke(shape, with: .color(.white), lineWidth: 2)
            }
            if snapshot.showNames, rect.height > 18, rect.width > 10 {
                let name = MusicTheory.letterName(staffStep: note.staffStep, accidental: note.accidental)
                ctx.draw(Text(name).font(.system(size: min(11, rect.width * 0.55), weight: .bold))
                            .foregroundColor(.white.opacity(0.9)),
                         at: CGPoint(x: rect.midX, y: rect.maxY - 9), anchor: .center)
            }
        }

        // The line where notes meet the keys.
        ctx.fill(Path(CGRect(x: 0, y: size.height - 2, width: size.width, height: 2)),
                 with: .color(Theme.accent.opacity(0.9)))
    }
}
