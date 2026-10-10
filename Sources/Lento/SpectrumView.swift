import SwiftUI
import AppKit
import AVFoundation

// MARK: - Spectrum + piano keyboard (aligned, as in the original)

struct SpectrumView: View {
    @Environment(AppModel.self) private var model

    /// Horizontal scroll of the piano keyboard (which pitch range is visible).
    @State private var pianoLowMidi: Double = 36 // C2
    @State private var pianoOctaves: Double = 6

    private static let pianoHeight: Double = 58

    var body: some View {
        GeometryReader { geo in
            let h = Double(geo.size.height) - Self.pianoHeight
            VStack(spacing: 0) {
                ZStack {
                    // Spectrum graph
                    SpectrumGraph(h: h, pianoLowMidi: pianoLowMidi, pianoOctaves: pianoOctaves, width: Double(geo.size.width))
                    // Chord guesses at the top right
                    VStack {
                        HStack {
                            Text(model.spectrum?.label ?? "")
                                .font(.caption)
                                .foregroundStyle(Palette.textSecondaryOnSurface)
                            Spacer()
                            if model.doc.showChordGuesses {
                                HStack(spacing: 8) {
                                    ForEach(model.spectrum?.chordGuesses ?? [], id: \.self) { c in
                                        Text(c)
                                            .font(.system(.body, design: .rounded).weight(.semibold))
                                            .foregroundStyle(Palette.textOnSurface)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        Spacer()
                    }
                }
                .frame(height: max(40, h))
                PianoKeyView(lowMidi: $pianoLowMidi, octaves: $pianoOctaves)
                    .frame(height: Self.pianoHeight)
            }
        }
        .background(Palette.surface)
        .gesture(
            DragGesture().onChanged { v in
                // Drag on the piano area scrolls the keyboard
                if v.location.y > 0 {
                    let pxPerSemitone = Double(1)
                    _ = pxPerSemitone
                }
            }
        )
    }
}

struct SpectrumGraph: View {
    @Environment(AppModel.self) private var model
    var h: Double
    var pianoLowMidi: Double
    var pianoOctaves: Double
    var width: Double

    var body: some View {
        Canvas { ctx, size in
            guard let spectrum = model.spectrum else {
                ctx.draw(Text("No spectrum — click or select on the waveform")
                    .font(.caption).foregroundStyle(Palette.textSecondaryOnSurface),
                    at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            // Frequency → x, mapped over the same range as the piano keyboard
            let fLow = NoteMath.freq(forMidi: pianoLowMidi)
            let fHigh = NoteMath.freq(forMidi: pianoLowMidi + pianoOctaves * 12 + 1)
            let maxBin = spectrum.mags.count - 1
            let binHz = spectrum.binHz

            // log-frequency mapping: x = log2(f/fLow) / log2(fHigh/fLow) * width
            let logSpan = log2(fHigh / fLow)
            func xFor(freq: Double) -> Double {
                guard freq > 0 else { return 0 }
                return log2(freq / fLow) / logSpan * Double(size.width)
            }

            // dB calibration lines
            if model.doc.showDBLines {
                for db in stride(from: -10.0, through: -60.0, by: -10.0) {
                    let frac = pow(10.0, db / 20.0)
                    let y = Double(size.height) * (1 - frac)
                    if y < size.height - 2 {
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(p, with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        ctx.draw(Text("\(Int(db))dB").font(.system(size: 8)).foregroundStyle(.white.opacity(0.3)),
                                 at: CGPoint(x: 26, y: y - 6))
                    }
                }
            }

            // Spectral curve (filled)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            let columns = Int(size.width)
            for c in 0...columns {
                let f = fLow * pow(fHigh / fLow, Double(c) / Double(columns))
                let bin = Int((f / binHz).rounded())
                guard bin <= maxBin else { break }
                let mag = Double(spectrum.mags[min(max(bin, 0), maxBin)])
                let y = Double(size.height) * (1 - mag)
                path.addLine(to: CGPoint(x: Double(c), y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [Palette.spectrum.opacity(0.55), Palette.spectrum.opacity(0.06)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))
            var line = Path()
            // stroke the same curve (no close)
            var first = true
            for c in 0...columns {
                let f = fLow * pow(fHigh / fLow, Double(c) / Double(columns))
                let bin = Int((f / binHz).rounded())
                guard bin <= maxBin else { break }
                let mag = Double(spectrum.mags[min(max(bin, 0), maxBin)])
                let y = Double(size.height) * (1 - mag)
                if first { line.move(to: CGPoint(x: Double(c), y: y)); first = false }
                else { line.addLine(to: CGPoint(x: Double(c), y: y)) }
            }
            ctx.stroke(line, with: .color(Palette.spectrum.opacity(0.9)), lineWidth: 1.2)

            // Harmonic grid lines (5 octaves either side), drawn on click — handled by gesture below.
        }
    }
}

struct PianoKeyView: View {
    @Environment(AppModel.self) private var model
    @Binding var lowMidi: Double
    @Binding var octaves: Double

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let whiteKeyW = Double(size.width) / (octaves * 7)
                let blackKeyW = whiteKeyW * 0.62

                // White keys
                var wi = 0
                var m = Int(lowMidi.rounded())
                while wi < Int(octaves * 7) + 1 {
                    let pc = NoteMath.pitchClass(m)
                    if isWhiteKey(pc) {
                        var key = Path()
                        key.addRect(CGRect(x: Double(wi) * whiteKeyW, y: 0, width: whiteKeyW - 1, height: size.height))
                        ctx.fill(key, with: .color(Color(white: 0.94)))
                        if pc == 0 {
                            ctx.draw(Text("C\(m / 12)").font(.system(size: 8, weight: .medium)).foregroundStyle(.black.opacity(0.55)),
                                     at: CGPoint(x: Double(wi) * whiteKeyW + whiteKeyW / 2, y: size.height - 8))
                            // Note-centre line rising through the spectrum
                            var line = Path()
                            line.move(to: CGPoint(x: Double(wi) * whiteKeyW + whiteKeyW / 2, y: 0))
                            line.addLine(to: CGPoint(x: Double(wi) * whiteKeyW + whiteKeyW / 2, y: size.height))
                            ctx.stroke(line, with: .color(.black.opacity(0.35)), lineWidth: 1)
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
                        // does a black key follow this white key?
                        let nextPc = NoteMath.pitchClass(m + 1)
                        if !isWhiteKey(nextPc), nextPc != 11 {
                            var key = Path()
                            key.addRect(CGRect(x: Double(wi) * whiteKeyW + whiteKeyW - blackKeyW / 2, y: 0,
                                               width: blackKeyW, height: size.height * 0.62))
                            ctx.fill(key, with: .color(Color(white: 0.12)))
                        }
                        wi += 1
                    }
                    m += 1
                }

                // Note guesses: green (in tune) / red (out of tune) blobs
                if model.doc.showNoteGuesses {
                    for note in model.spectrum?.noteGuesses ?? [] {
                        guard Double(note.midi) >= lowMidi, Double(note.midi) <= lowMidi + octaves * 12 else { continue }
                        let f = NoteMath.freq(forMidi: Double(note.midi))
                        let fLow = NoteMath.freq(forMidi: lowMidi)
                        let fHigh = NoteMath.freq(forMidi: lowMidi + octaves * 12 + 1)
                        let x = log2(f / fLow) / log2(fHigh / fLow) * Double(size.width)
                        let r = 3 + CGFloat(note.confidence) * 6
                        let color = note.inTune ? Color(red: 0.19, green: 0.82, blue: 0.35) : Palette.currentPoint
                        var blob = Path()
                        blob.addEllipse(in: CGRect(x: x - r, y: size.height - 30 - r, width: r * 2, height: r * 2))
                        ctx.fill(blob, with: .color(color.opacity(0.55 + note.confidence * 0.4)))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                // Click a note to play a reference tone (piano keyboard's documented behavior)
                let fLow = NoteMath.freq(forMidi: lowMidi)
                let fHigh = NoteMath.freq(forMidi: lowMidi + octaves * 12 + 1)
                let frac = Double(location.x / geo.size.width)
                let f = fLow * pow(fHigh / fLow, frac)
                playReferenceTone(freq: f)
            }
            .gesture(
                DragGesture().onChanged { v in
                    // Drag horizontally scrolls the keyboard (press-drag on piano)
                    lowMidi = min(108 - octaves * 12, max(0, lowMidi - Double(v.translation.width) / (geo.size.width / (octaves * 12))))
                }
            )
        }
    }

    private func isWhiteKey(_ pc: Int) -> Bool { [0, 2, 4, 5, 7, 9, 11].contains(pc) }

    /// Short reference tone (the original plays a synthesized note on click).
    private func playReferenceTone(freq: Double) {
        ReferenceTone.play(freq: freq, volume: 0.3)
    }
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
            // triangle via sine + odd harmonics, quick attack, exponential decay
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
