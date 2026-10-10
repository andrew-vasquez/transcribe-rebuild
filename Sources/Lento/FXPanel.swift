import SwiftUI
import AppKit

// MARK: - Audio Effects and Controls (glass utility window, six pages as the original)

struct FXPanelView: View {
    @Environment(AppModel.self) private var model
    @State private var page: FXPage = .speed

    enum FXPage: String, CaseIterable, Identifiable {
        case mono = "Mono/Karaoke"
        case eq = "EQ"
        case tuning = "Tuning"
        case transposition = "Transposition"
        case speed = "Speed"
        case misc = "Misc"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Page tabs, with the "bullet" indicating the page is active (as the original does)
            HStack(spacing: 4) {
                ForEach(FXPage.allCases) { p in
                    let active = isActive(p)
                    Button {
                        page = p
                    } label: {
                        VStack(spacing: 1) {
                            HStack(spacing: 3) {
                                if active { Circle().fill(.green).frame(width: 5, height: 5) }
                                Text(p.rawValue).font(.callout.weight(active ? .semibold : .regular))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(page == p ? Color.primary.opacity(0.12) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.bar)

            Divider()

            Group {
                switch page {
                case .mono: MonoPage()
                case .eq: EQPage()
                case .tuning: TuningPage()
                case .transposition: TranspositionPage()
                case .speed: SpeedPage()
                case .misc: MiscPage()
                }
            }
            .padding(14)
            .frame(maxWidth: 640)
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(.ultraThinMaterial)
    }

    private func isActive(_ p: FXPage) -> Bool {
        switch p {
        case .mono: return model.doc.fx.mixActive
        case .eq: return model.doc.fx.eqActive
        case .tuning: return model.doc.fx.tuningCentsTotal != 0
        case .transposition: return model.doc.fx.transpositionSemitones != 0 || model.doc.fx.transpositionCents != 0
        case .speed: return model.doc.fx.speed != 100
        case .misc: return model.doc.clicksOn
        }
    }
}

// MARK: - Active / Bypass header shared by the effect pages

struct FxPageHeader: View {
    var title: String
    @Binding var active: Bool
    var onClear: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Picker("", selection: $active) {
                Text("Active").tag(true)
                Text("Bypass").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            Button("Clear", action: onClear)
        }
        .padding(.bottom, 10)
    }
}

// MARK: - Mono / Karaoke page

struct MonoPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            FxPageHeader(title: "Mono / Karaoke",
                         active: Binding(get: { model.doc.fx.mixActive },
                                         set: { model.doc.fx.mixActive = $0; model.applyFX() })) {
                model.doc.fx.mixMode = .stereo
                model.doc.fx.mixBalance = 0
                model.doc.fx.mixActive = false
                model.applyFX()
            }
            if model.doc.fileInfo == nil {
                Text("No sound file").foregroundStyle(.secondary)
            } else if model.audio.channels < 2 {
                Text("The sound file is mono — these controls are disabled.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    Picker("Mode", selection: Binding(get: { model.doc.fx.mixMode }, set: { model.doc.fx.mixMode = $0; model.applyFX() })) {
                        Text("Stereo").tag(MixMode.stereo)
                        Text("Mono").tag(MixMode.mono)
                        Text("Left").tag(MixMode.left)
                        Text("Right").tag(MixMode.right)
                        Text("Karaoke").tag(MixMode.karaoke)
                    }
                    .pickerStyle(.segmented)
                    if model.doc.fx.mixMode == .karaoke {
                        Slider(value: Binding(get: { model.doc.fx.mixBalance },
                                             set: { model.doc.fx.mixBalance = $0; model.applyFX() }),
                               in: -1...1)
                        .frame(width: 180)
                        .help("Adjust for maximum cancellation")
                    }
                }
                Text("Out-of-phase mixing can cancel center-panned material (often the vocal). " +
                     "Adjust the slider for maximum cancellation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            Spacer()
        }
    }
}

// MARK: - EQ page: 31 vertical sliders, elastic neighbours (shift accelerates)

struct EQPage: View {
    @Environment(AppModel.self) private var model
    @State private var draggingIndex: Int?

    var body: some View {
        VStack(spacing: 8) {
            FxPageHeader(title: "31-Band Graphic EQ",
                         active: Binding(get: { model.doc.fx.eqActive },
                                         set: { model.doc.fx.eqActive = $0; model.applyFX() })) {
                model.doc.fx.eqGains = Array(repeating: 0.0, count: EQBands.count)
                model.applyFX()
            }
            if !model.doc.fx.eqActive {
                Text("Bypassed").foregroundStyle(.secondary).padding(.bottom, 8)
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<EQBands.count, id: \.self) { i in
                    EQSlider(index: i, draggingIndex: $draggingIndex)
                }
            }
            .frame(height: 160)
            .glassEffect(in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 2)

            HStack {
                Text("Presets")
                    .font(.callout.weight(.medium))
                Picker("", selection: Binding(get: { 0 },
                                              set: { idx in
                                                guard model.doc.eqPresets.indices.contains(idx) else { return }
                                                let p = model.doc.eqPresets[idx]
                                                model.doc.fx.eqGains = p.gains
                                                model.doc.fx.eqActive = true
                                                model.applyFX()
                                              })) {
                    ForEach(Array(model.doc.eqPresets.enumerated()), id: \.offset) { idx, p in
                        Text(p.name).tag(idx)
                    }
                }
                .frame(width: 220)
                .disabled(model.doc.eqPresets.isEmpty)
                Spacer()
                Button("Save Preset…") {
                    let alert = NSAlert()
                    alert.messageText = "Save EQ preset"
                    alert.informativeText = "Enter a name for the current EQ settings"
                    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
                    alert.accessoryView = input
                    alert.addButton(withTitle: "Save")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty {
                        model.doc.eqPresets.append((input.stringValue, model.doc.fx.eqGains))
                        model.doc.saveEqPresets()
                    }
                }
                Button("Reset Defaults") {
                    model.doc.eqPresets = EQBands.defaultPresets()
                    model.doc.saveEqPresets()
                }
            }
            .padding(.top, 4)
        }
    }
}

struct EQSlider: View {
    @Environment(AppModel.self) private var model
    var index: Int
    @Binding var draggingIndex: Int?

    var body: some View {
        let gain = model.doc.fx.eqGains[index]
        let center = EQBands.centers[index]
        VStack(spacing: 2) {
            Text(shortFreq(center))
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Capsule()
                .fill(gain > 0 ? Palette.wave.opacity(0.8) : Palette.selectionEdge.opacity(0.8))
                .frame(width: 8, height: max(1, CGFloat(abs(gain)) / 80 * 26))
            Slider(value: Binding(
                get: { model.doc.fx.eqGains[index] },
                set: { newValue in
                    var v = min(max(newValue, EQBands.minGain), EQBands.maxGain)
                    // Elastic neighbours while dragging (shift → faster spread)
                    if draggingIndex == index {
                        let shift = NSEvent.modifierFlags.contains(.shift)
                        let old = model.doc.fx.eqGains[index]
                        let delta = v - old
                        let spread = shift ? 0.55 : 0.25
                        if index > 0 { model.doc.fx.eqGains[index - 1] += delta * spread }
                        if index < EQBands.count - 1 { model.doc.fx.eqGains[index + 1] += delta * spread }
                    }
                    model.doc.fx.eqGains[index] = v
                    model.applyFX()
                }
            ), in: EQBands.minGain...EQBands.maxGain)
            .frame(width: 22)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onChanged { _ in draggingIndex = index }
            )
        }
        .frame(width: 24)
    }

    private func shortFreq(_ f: Double) -> String {
        if f >= 1000 { let k = f / 1000; return k == k.rounded() && k >= 10 ? "\(Int(k))k" : String(format: "%.1fk", k) }
        if f == f.rounded() { return "\(Int(f))" }
        return String(format: "%.0f", f)
    }
}

// MARK: - Tuning page (octaves / semitones / cents + reference note)

struct TuningPage: View {
    @Environment(AppModel.self) private var model
    @State private var hzField = "440"

    var body: some View {
        VStack(spacing: 14) {
            FxPageHeader(title: "Tuning",
                         active: Binding(get: { model.doc.fx.tuningCentsTotal != 0 },
                                         set: { on in
                                             if !on {
                                                 model.doc.fx.octaves = 0
                                                 model.doc.fx.semitones = 0
                                                 model.doc.fx.cents = 0
                                                 model.applyFX()
                                             }
                                         })) {
                model.doc.fx.octaves = 0
                model.doc.fx.semitones = 0
                model.doc.fx.cents = 0
                model.applyFX()
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("Octaves").font(.caption)
                    Slider(value: Binding(get: { Double(model.doc.fx.octaves) },
                                           set: { model.doc.fx.octaves = Int($0.rounded()); model.applyFX() }),
                           in: -3...3, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Semitones").font(.caption)
                    Slider(value: Binding(get: { Double(model.doc.fx.semitones) },
                                           set: { model.doc.fx.semitones = Int($0.rounded()); model.applyFX() }),
                           in: -11...11, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Cents").font(.caption)
                    Slider(value: Binding(get: { model.doc.fx.cents },
                                           set: { model.doc.fx.cents = $0; model.applyFX() }),
                           in: -50...50)
                }
                .frame(width: 160)
            }
            HStack {
                TextField("440", text: $hzField)
                    .frame(width: 60)
                    .onSubmit { applyHzPreview() }
                Text(String(format: "becomes %.2f Hz", 440.0 * pow(2.0, model.doc.fx.tuningCentsTotal / 1200.0)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Toggle("Analog lock (pitch and speed interlocked, like tape)", isOn: Binding(
                get: { model.doc.fx.analogLock },
                set: { model.doc.fx.analogLock = $0; model.applyFX() }))
            Divider()
            HStack {
                Button("Play reference note A") {
                    ReferenceTone.play(freq: 440.0 * pow(2.0, (model.doc.fx.tuningCentsTotal + Double(model.doc.fx.transpositionSemitones) * 100 + model.doc.fx.transpositionCents) / 1200.0),
                                       volume: 0.3)
                }
                Text("Compare by ear, or align a spectrum peak to a note centre by adjusting cents.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func applyHzPreview() {
        _ = Double(hzField)
    }
}

// MARK: - Transposition page

struct TranspositionPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            FxPageHeader(title: "Transposition",
                         active: Binding(get: { model.doc.fx.transpositionSemitones != 0 || model.doc.fx.transpositionCents != 0 },
                                         set: { on in
                                             if !on {
                                                 model.doc.fx.transpositionSemitones = 0
                                                 model.doc.fx.transpositionCents = 0
                                             }
                                         })) {
                model.doc.fx.transpositionSemitones = 0
                model.doc.fx.transpositionCents = 0
                model.refreshSpectrum()
            }
            Text("Transposition does not affect the sound. It changes what Transcribe calls “A”: the naming used by the piano keyboard, reference notes, and the spectrum — for transposing instruments (Bb trumpet, capo-ed guitar) and out-of-tune instruments.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480, alignment: .leading)
            HStack {
                Stepper("Semitones: \(model.doc.fx.transpositionSemitones)",
                        value: Binding(get: { model.doc.fx.transpositionSemitones },
                                       set: { model.doc.fx.transpositionSemitones = $0; model.refreshSpectrum() }),
                        in: -24...24)
                Stepper("Cents: \(Int(model.doc.fx.transpositionCents))",
                        value: Binding(get: { Int(model.doc.fx.transpositionCents) },
                                       set: { model.doc.fx.transpositionCents = Double($0); model.refreshSpectrum() }),
                        in: -50...50)
            }
            HStack {
                Text("Presets:").font(.caption)
                ForEach([("Bb instruments", -2), ("Eb instruments", 3), ("Bass (octave)", -12), ("Guitar capo 3", 3)], id: \.0) { name, semis in
                    Button(name) {
                        model.doc.fx.transpositionSemitones = semis
                        model.refreshSpectrum()
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Speed page

struct SpeedPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            FxPageHeader(title: "Speed",
                         active: Binding(get: { model.doc.fx.speed != 100 },
                                         set: { on in
                                             if !on { model.setSpeed(100) }
                                         })) {
                model.setSpeed(100)
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("Speed: \(String(format: "%.2f", model.doc.fx.speed))%").font(.callout)
                    Slider(value: Binding(get: { model.doc.fx.speed },
                                           set: { model.setSpeed($0) }),
                           in: 5...200)
                    .frame(width: 320)
                    HStack {
                        ForEach([100.0, 70, 50, 35, 20, 5], id: \.self) { pct in
                            Button("\(Int(pct))%") { model.setSpeed(pct) }
                                .buttonStyle(.bordered)
                                .frame(width: 52)
                        }
                        Button("−3%") { model.nudgeSpeed(-3) }.buttonStyle(.bordered)
                        Button("−1%") { model.nudgeSpeed(-1) }.buttonStyle(.bordered)
                        Button("+1%") { model.nudgeSpeed(1) }.buttonStyle(.bordered)
                        Button("+3%") { model.nudgeSpeed(3) }.buttonStyle(.bordered)
                    }
                }
            }
            Toggle("Analog lock (pitch and speed interlocked, like tape)", isOn: Binding(
                get: { model.doc.fx.analogLock },
                set: { model.doc.fx.analogLock = $0; model.applyFX() }))
            if let tempo = model.doc.computeTempo() {
                Text(String(format: "Original tempo: %.1f bpm — altered speed: %.1f bpm", tempo.bpmOriginal, tempo.bpmAltered))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Misc page: volume, clicks, and stored loops

struct MiscPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                LabeledContent("Volume") {
                    Slider(value: Binding(get: { model.doc.fx.volume },
                                          set: { model.doc.fx.volume = $0; model.applyFX() }),
                           in: 0...200)
                    .frame(width: 220)
                    Text("\(Int(model.doc.fx.volume))%")
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }
                LabeledContent("Clicks") {
                    Slider(value: Binding(get: { model.doc.clickVolume },
                                          set: { model.doc.clickVolume = $0; model.applyFX() }),
                           in: 0...1)
                    .frame(width: 120)
                    .disabled(!model.doc.clicksOn)
                }
            }
            Divider()
            HStack {
                Text("Loops").font(.callout.weight(.medium))
                Spacer()
                Text("Shift-click a slot to store the current position/selection; click to recall.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                    ForEach(0..<min(model.doc.loops.count, 20), id: \.self) { i in
                        LoopSlotView(index: i)
                    }
                }
            }
        }
    }
}

struct LoopSlotView: View {
    @Environment(AppModel.self) private var model
    var index: Int
    var body: some View {
        let loop = model.doc.loops[index]
        let hasFx = loop.fxApplied
        Button {
            model.recallLoop(index)
            model.play()
        } label: {
            HStack {
                Text("\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                if hasFx { Image(systemName: "slider.horizontal.3").font(.system(size: 9)) }
                Text(loop.name.isEmpty ? TimeFormat.short(loop.position) : loop.name)
                    .lineLimit(1)
                    .font(.callout)
                Spacer()
                // Location indicator: rough position within the track
                GeometryReader { geo in
                    let frac = model.doc.fileInfo.map { loop.position / max($0.duration, 0.001) } ?? 0
                    Rectangle()
                        .fill(Palette.blockColor(loop.colorIndex).opacity(0.85))
                        .frame(width: 3, height: geo.size.height)
                        .offset(x: min(max(0, frac) * (geo.size.width - 3), 0))
                }
                .frame(width: 44, height: 10)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(loop.hasPosition ? Palette.blockColor(loop.colorIndex).opacity(0.18) : Color.primary.opacity(0.08))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture().modifiers(.shift).onEnded {
                model.storeLoop(index)
                model.doc.loops[index].colorIndex = index % Palette.blockColors.count
            }
        )
        .contextMenu {
            Button("Name…") {
                let alert = NSAlert()
                alert.messageText = "Name loop \(index + 1)"
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
                input.stringValue = loop.name
                alert.accessoryView = input
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    model.doc.loops[index].name = input.stringValue
                    model.doc.modified = true
                }
            }
            Button("Color: next") {
                model.doc.loops[index].colorIndex = (loop.colorIndex + 1) % Palette.blockColors.count
                model.doc.modified = true
            }
            Button("Store Fx with this loop") {
                model.doc.loops[index].fx = model.doc.fx
                model.doc.loops[index].fxApplied = true
                model.doc.modified = true
            }
            Button("Clear Fx") {
                model.doc.loops[index].fxApplied = false
                model.doc.modified = true
            }
            Divider()
            Button("Clear", role: .destructive) {
                model.doc.loops[index] = StoredLoop()
                model.doc.modified = true
            }
        }
        .help("Click to recall • shift-click to store • right-click for options")
    }
}
