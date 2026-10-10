import SwiftUI
import AppKit
import AVFoundation

// MARK: - Spectrum + piano keyboard (aligned, as in the original)

struct SpectrumView: View {
    @Environment(AppModel.self) private var model
    @State private var pianoLowMidi: Double = 36 // C2
    @State private var pianoOctaves: Double = 6

    var body: some View {
        GeometryReader { geo in
            let spectrumH = Double(geo.size.height) - 58
            VStack(spacing: 0) {
                ZStack {
                    SpectrumGraph(h: spectrumH,
                                  pianoLowMidi: pianoLowMidi,
                                  pianoOctaves: pianoOctaves,
                                  width: Double(geo.size.width))
                    SpectrumHeader()
                }
                .frame(height: max(40, spectrumH))
                PianoKeyView(lowMidi: $pianoLowMidi, octaves: $pianoOctaves)
                    .frame(height: 58)
            }
        }
        .background(Palette.surface)
    }
}

/// Spectrum source label (left) + chord-guess glass chips (right).
private struct SpectrumHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            HStack {
                Text(model.spectrum?.label ?? "")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondaryOnSurface)
                Spacer()
                if model.doc.showChordGuesses {
                    HStack(spacing: 6) {
                        ForEach(model.spectrum?.chordGuesses ?? [], id: \.self) { guess in
                            Text(guess)
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                                .foregroundStyle(Palette.textOnSurface)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .modifier(GlassChip(interactive: false, cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

struct SpectrumGraph: View {
    @Environment(AppModel.self) private var model
    var h: Double
    var pianoLowMidi: Double
    var pianoOctaves: Double
    var width: Double
    @State private var hoverX: Double?

    var body: some View {
        ZStack {
            canvasBody
            hoverReadout
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoverX = Double(point.x)
            case .ended: hoverX = nil
            }
        }
        .clipped()
    }

    private var canvasBody: some View {
        Canvas { ctx, size in
            drawSpectrum(ctx: ctx, size: size)
        }
    }

    private func drawSpectrum(ctx: GraphicsContext, size: CGSize) {
        guard let spectrum = model.spectrum else {
            ctx.draw(Text("No spectrum — click or select on the waveform")
                .font(.caption).foregroundStyle(Palette.textSecondaryOnSurface),
                at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let fLow = NoteMath.freq(forMidi: pianoLowMidi)
        let fHigh = NoteMath.freq(forMidi: pianoLowMidi + pianoOctaves * 12 + 1)
        drawDBLines(ctx: ctx, size: size)
        drawCurve(ctx: ctx, size: size, spectrum: spectrum, fLow: fLow, fHigh: fHigh)
    }

    private func drawDBLines(ctx: GraphicsContext, size: CGSize) {
        guard model.doc.showDBLines else { return }
        for db in stride(from: -10.0, through: -60.0, by: -10.0) {
            let frac = pow(10.0, db / 20.0)
            let y = Double(size.height) * (1 - frac)
            if y < size.height - 2 {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(Palette.tickLine.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                ctx.draw(Text("\(Int(db))dB").font(.system(size: 8)).foregroundStyle(Palette.tickText),
                         at: CGPoint(x: 26, y: y - 6))
            }
        }
    }

    private func drawCurve(ctx: GraphicsContext, size: CGSize, spectrum: SpectrumResult, fLow: Double, fHigh: Double) {
        let columns = Int(size.width)
        let pts: [(Double, Double)] = (0...columns).compactMap { c in
            let f = fLow * pow(fHigh / fLow, Double(c) / Double(columns))
            let bin = Int((f / spectrum.binHz).rounded())
            guard bin <= spectrum.mags.count - 1 else { return nil }
            let mag = Double(spectrum.mags[max(0, bin)])
            return (Double(c), Double(size.height) * (1 - mag))
        }
        guard let firstPt = pts.first else { return }

        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (x, y) in pts { path.addLine(to: CGPoint(x: x, y: y)) }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .linearGradient(
            Gradient(colors: [Palette.spectrum.opacity(0.55), Palette.spectrum.opacity(0.06)]),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: 0, y: size.height)))

        var line = Path()
        line.move(to: CGPoint(x: firstPt.0, y: firstPt.1))
        for (x, y) in pts.dropFirst() { line.addLine(to: CGPoint(x: x, y: y)) }
        ctx.stroke(line, with: .color(Palette.spectrum.opacity(0.9)), lineWidth: 1.2)
    }

    /// Hover crosshair: note + frequency readout in a glass chip.
    @ViewBuilder
    private var hoverReadout: some View {
        if let x = hoverX, x > 0, x < width {
            ZStack {
                Rectangle()
                    .fill(Palette.tickLine)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .position(x: x, y: 0)
                HoverChip(x: x, width: width, pianoLowMidi: pianoLowMidi, pianoOctaves: pianoOctaves)
            }
        }
    }

    private struct HoverChip: View {
        var x: Double
        var width: Double
        var pianoLowMidi: Double
        var pianoOctaves: Double

        var body: some View {
            let fLow = NoteMath.freq(forMidi: pianoLowMidi)
            let fHigh = NoteMath.freq(forMidi: pianoLowMidi + pianoOctaves * 12 + 1)
            let freq = fLow * pow(fHigh / fLow, x / width)
            let midi = Int(NoteMath.midi(forFreq: freq).rounded())
            return Text("\(NoteMath.name(forMidi: midi))  ·  \(String(format: "%.1f", freq)) Hz")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.textOnSurface)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .modifier(GlassChip(interactive: false, cornerRadius: 7))
                .position(x: min(max(x, 70), width - 70), y: 18)
        }
    }
}

struct PianoKeyView: View {
    @Environment(AppModel.self) private var model
    @Binding var lowMidi: Double
    @Binding var octaves: Double
    @State private var hoveredMidi: Int?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawKeys(ctx: ctx, size: size)
                drawNoteGuesses(ctx: ctx, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let w = Double(geo.size.width)
                    // black keys occupy the top 62% of the strip
                    if point.y < geo.size.height * 0.62,
                       let black = midiAtBlack(x: Double(point.x), width: w) {
                        hoveredMidi = black
                    } else {
                        hoveredMidi = midiAtWhite(x: Double(point.x), width: w)
                    }
                case .ended:
                    hoveredMidi = nil
                }
            }
            .onTapGesture { location in
                let fLow = NoteMath.freq(forMidi: lowMidi)
                let fHigh = NoteMath.freq(forMidi: lowMidi + octaves * 12 + 1)
                let frac = Double(location.x / geo.size.width)
                ReferenceTone.play(freq: fLow * pow(fHigh / fLow, frac), volume: 0.3)
            }
            .gesture(
                DragGesture().onChanged { v in
                    lowMidi = min(108 - octaves * 12,
                                  max(0, lowMidi - Double(v.translation.width) / (geo.size.width / (octaves * 12))))
                }
            )
        }
    }

    private func isLight() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .vibrantLight]) != nil
    }

    private func drawKeys(ctx: GraphicsContext, size: CGSize) {
        let whiteKeyW = Double(size.width) / (octaves * 7)
        let blackKeyW = whiteKeyW * 0.62
        let light = isLight()
        let whiteKeyColor: Color = light ? Color(white: 1.0) : Color(white: 0.94)
        let blackKeyColor: Color = light ? Color(white: 0.16) : Color(white: 0.12)

        // White keys + C labels
        var wi = 0
        var m = Int(lowMidi.rounded())
        while wi < Int(octaves * 7) + 1 {
            let pc = NoteMath.pitchClass(m)
            if isWhiteKey(pc) {
                let x = Double(wi) * whiteKeyW
                var key = Path()
                key.addRect(CGRect(x: x, y: 0, width: whiteKeyW - 1, height: size.height))
                ctx.fill(key, with: .color(hoveredMidi == m ? whiteKeyColor.opacity(0.8) : whiteKeyColor))
                if pc == 0 {
                    ctx.draw(Text("C\(m / 12)").font(.system(size: 8, weight: .medium)).foregroundStyle(Palette.tickText),
                             at: CGPoint(x: x + whiteKeyW / 2, y: size.height - 8))
                    var line = Path()
                    line.move(to: CGPoint(x: x + whiteKeyW / 2, y: 0))
                    line.addLine(to: CGPoint(x: x + whiteKeyW / 2, y: size.height))
                    ctx.stroke(line, with: .color(Color.black.opacity(0.35)), lineWidth: 1)
                }
                wi += 1
            }
            m += 1
        }
        // Black keys
        wi = 0
        m = Int(lowMidi.rounded())
        while wi < Int(octaves * 7) + 1 {
            let pc = NoteMath.pitchClass(m)
            if isWhiteKey(pc) {
                let nextPc = NoteMath.pitchClass(m + 1)
                if !isWhiteKey(nextPc), nextPc != 11 {
                    let x = Double(wi) * whiteKeyW + whiteKeyW - blackKeyW / 2
                    var key = Path()
                    key.addRect(CGRect(x: x, y: 0, width: blackKeyW, height: size.height * 0.62))
                    ctx.fill(key, with: .color(hoveredMidi == m + 1 ? blackKeyColor.opacity(0.7) : blackKeyColor))
                }
                wi += 1
            }
            m += 1
        }
    }

    private func drawNoteGuesses(ctx: GraphicsContext, size: CGSize) {
        guard model.doc.showNoteGuesses else { return }
        for note in model.spectrum?.noteGuesses ?? [] {
            guard Double(note.midi) >= lowMidi, Double(note.midi) <= lowMidi + octaves * 12 else { continue }
            let f = NoteMath.freq(forMidi: Double(note.midi))
            let fLow = NoteMath.freq(forMidi: lowMidi)
            let fHigh = NoteMath.freq(forMidi: lowMidi + octaves * 12 + 1)
            let x = log2(f / fLow) / log2(fHigh / fLow) * Double(size.width)
            let r = 3 + CGFloat(note.confidence) * 6
            let color: Color = note.inTune ? Color(red: 0.19, green: 0.82, blue: 0.35) : Palette.currentPoint
            var blob = Path()
            blob.addEllipse(in: CGRect(x: x - r, y: size.height - 30 - r, width: r * 2, height: r * 2))
            ctx.fill(blob, with: .color(color.opacity(0.55 + note.confidence * 0.4)))
        }
    }

    private func midiAtWhite(x: Double, width: Double) -> Int? {
        let whiteKeyW = width / (octaves * 7)
        guard whiteKeyW > 0 else { return nil }
        var wi = min(max(Int((x / whiteKeyW).rounded(.down)), 0), Int(octaves * 7))
        var count = -1
        var m = Int(lowMidi.rounded())
        while m < Int(lowMidi.rounded()) + Int(octaves * 12) + 14 {
            if isWhiteKey(NoteMath.pitchClass(m)) {
                count += 1
                if count == wi { return m }
            }
            m += 1
        }
        _ = wi
        return nil
    }

    private func midiAtBlack(x: Double, width: Double) -> Int? {
        let whiteKeyW = width / (octaves * 7)
        let blackKeyW = whiteKeyW * 0.62
        var wi = 0
        var m = Int(lowMidi.rounded())
        while wi < Int(octaves * 7) + 1 {
            let pc = NoteMath.pitchClass(m)
            if isWhiteKey(pc) {
                let nextPc = NoteMath.pitchClass(m + 1)
                if !isWhiteKey(nextPc), nextPc != 11 {
                    let bx = Double(wi) * whiteKeyW + whiteKeyW - blackKeyW / 2
                    if x >= bx && x <= bx + blackKeyW { return m + 1 }
                }
                wi += 1
            }
            m += 1
        }
        return nil
    }

    private func isWhiteKey(_ pc: Int) -> Bool { [0, 2, 4, 5, 7, 9, 11].contains(pc) }
}

/// Synthesizes a short piano-ish reference tone (triangle wave, like the original's tuning notes).
enum ReferenceTone {
    private static var engine: AVAudioEngine?
    private static var player: AVAudioPlayerNode?

    static func play(freq: Double, volume: Float) {
        let rate = 44100.0
        let dur = 0.5
        let n = Int(dur * rate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let data = buf.floatChannelData![0]
        for i in 0..<n {
            let t = Double(i) / rate
            let phase = 2.0 * .pi * freq * t
            let env = min(1.0, t / 0.005) * exp(-t * 4)
            let tri = (2.0 / .pi) * asin(sin(phase))
            data[i] = Float(tri * env * Double(volume))
        }
        if engine == nil {
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: format)
            try? e.start()
            p.play()
            engine = e
            player = p
        }
        player?.scheduleBuffer(buf, at: nil, options: .interrupts)
        player?.volume = 1
    }
}
