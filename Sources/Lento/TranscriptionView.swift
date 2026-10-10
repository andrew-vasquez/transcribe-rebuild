import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared geometry + palette

struct WaveGeom {
    var width: Double
    var viewStart: TimeInterval
    var viewEnd: TimeInterval

    func x(for t: TimeInterval) -> Double {
        guard viewEnd > viewStart else { return 0 }
        return (t - viewStart) / (viewEnd - viewStart) * width
    }
    func t(forX x: Double) -> TimeInterval {
        guard viewEnd > viewStart else { return viewStart }
        return viewStart + x / width * (viewEnd - viewStart)
    }
}

enum Palette {
    // Adaptive palette: colors resolve per system appearance (Light/Dark/Auto).
    // Dark = pro-tool identity (amber on near-black). Light = dark-ink strokes on paper,
    // matching the original app's light look. The amber accent carries both modes.
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .vibrantLight]) != nil { return light }
            return dark
        })
    }
    private static func rgb(_ r: Double, _ g: Double, _ b: Double, a: Double = 1) -> NSColor {
        NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    static let surface = dyn(rgb(0.965, 0.965, 0.973), rgb(0.11, 0.11, 0.12))
    static let surfaceEdge = dyn(rgb(0, 0, 0, a: 0.10), rgb(1, 1, 1, a: 0.08))
    static let wave = dyn(rgb(0.78, 0.37, 0.0), rgb(1.0, 0.62, 0.04))
    static let waveDim = wave.opacity(0.55)
    static let selection = dyn(rgb(0.04, 0.52, 1.0, a: 0.18), rgb(0.04, 0.52, 1.0, a: 0.25))
    static let selectionEdge = Color(nsColor: .systemBlue)
    static let currentPoint = Color(nsColor: .systemRed)
    static let playLine = dyn(rgb(0, 0, 0, a: 0.85), rgb(1, 1, 1, a: 0.9))
    static let markerSection = dyn(rgb(0.31, 0.36, 0.78), rgb(0.48, 0.61, 1.0))
    static let markerMeasure = dyn(rgb(0.05, 0.52, 0.19), rgb(0.19, 0.82, 0.35))
    static let markerBeat = dyn(rgb(0, 0, 0, a: 0.55), rgb(0.75, 0.75, 0.75))
    static let spectrum = dyn(rgb(0.0, 0.45, 0.16), rgb(0.19, 0.82, 0.35))
    static let textOnSurface = dyn(rgb(0, 0, 0, a: 0.85), rgb(1, 1, 1, a: 0.92))
    static let textSecondaryOnSurface = dyn(rgb(0, 0, 0, a: 0.45), rgb(1, 1, 1, a: 0.45))
    static let tickLine = dyn(rgb(0, 0, 0, a: 0.25), rgb(1, 1, 1, a: 0.25))
    static let tickText = dyn(rgb(0, 0, 0, a: 0.4), rgb(1, 1, 1, a: 0.4))

    static func color(for kind: MarkerKind) -> Color {
        switch kind {
        case .section: return markerSection
        case .measure: return markerMeasure
        case .beat: return markerBeat
        }
    }

    static let blockColors: [Color] = [
        .yellow, .green, .cyan, .pink, .orange, .purple, .mint, .red
    ]
    static func blockColor(_ i: Int) -> Color { blockColors[i % blockColors.count] }
}

extension Color {
    var nsColor: NSColor { NSColor(self) }
}

// MARK: - Liquid Glass helpers (per swiftui-expert-skill liquid-glass.md)
// Glass after layout modifiers · GlassEffectContainer for grouped glass · interactive only on
// tappable elements · solid fallback when Reduce Transparency is on.

@MainActor
enum Liquid {
    @ViewBuilder
    static func chip<Content: View>(_ content: Content, interactive: Bool = true,
                                    tint: Color? = nil, cornerRadius: CGFloat = 10) -> some View {
        content.modifier(GlassChip(interactive: interactive, tint: tint, cornerRadius: cornerRadius))
    }
}

struct GlassChip: ViewModifier {
    var interactive: Bool
    var tint: Color?
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.primary.opacity(0.09)))
        } else {
            let base = tint.map { Glass.regular.tint($0) } ?? .regular
            content.glassEffect(interactive ? base.interactive() : base,
                                in: .rect(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - Main transcription window

struct TranscriptionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var splitterFraction: Double = 0.62   // waveform : spectrum share
    @State private var editingMarker: Marker?
    @State private var editingBlock: TextBlock?

    var body: some View {
        GeometryReader { geo in
            let spectrumH = (geo.size.height - 56 - 44 - 14 - 20 - 30) * (1.0 - splitterFraction)
            VStack(spacing: 0) {
                HeaderBar()
                    .frame(height: 48)
                if model.doc.fileInfo != nil {
                    MarkerZoneView(editingMarker: $editingMarker)
                        .frame(height: 30)
                    if model.doc.showTextZone {
                        TextZoneView(editingBlock: $editingBlock)
                            .frame(height: 46)
                    }
                    WaveformView()
                    ScrollBarView()
                        .frame(height: 14)
                    if model.doc.showNavigationBar {
                        NavigationBarView()
                            .frame(height: 20)
                    }
                    SplitterBar(fraction: $splitterFraction)
                        .frame(height: 10)
                    if model.doc.showSpectrum {
                        SpectrumView()
                            .frame(height: max(140, spectrumH))
                    }
                } else {
                    EmptyDropView()
                }
                LowerBarView()
                    .frame(height: 56)
            }
            // Rebuild (don't diff) the whole content tree when the document changes —
            // the empty↔loaded swap is a structural change.
            .id(model.doc.fileInfo?.url)
        }
        .background(Palette.surface)
        // NOTE: no SwiftUI .toolbar — the in-content HeaderBar above replaces it
        // (this macOS 27 beta corrupts the heap in NSToolbar's menu-form path).
        .navigationTitle((model.doc.modified ? "• " : "")
                        + (model.doc.xscURL?.lastPathComponent
                           ?? model.doc.fileInfo?.url.lastPathComponent
                           ?? "Lento"))
        .sheet(item: $editingMarker) { marker in
            MarkerEditSheet(marker: marker)
                .environment(model)
        }
        .sheet(item: $editingBlock) { block in
            TextBlockEditSheet(block: block)
                .environment(model)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: model.audio.playingPoint) { _, newPoint in
            if model.scrollFollow && model.audio.isPlaying {
                if newPoint < model.viewStart || newPoint > model.viewEnd {
                    model.scrollTo(center: newPoint)
                }
            }
        }
        .onChange(of: model.doc.selection) { _, _ in
            model.scheduleSpectrumRefresh()
        }
        .onChange(of: model.audio.isPaused) { _, paused in
            // The spectrum follows the paused point (the original reports it as
            // "the spectrum at the paused point").
            if paused { model.refreshSpectrum() }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { model.openAny(url: url) }
        }
        return true
    }
}

// MARK: - Drop target when no file is loaded

struct EmptyDropView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.wave.opacity(0.7))
            Text("Drop a sound file here")
                .font(.title3)
                .foregroundStyle(Palette.textOnSurface)
            Text("or use  File ▸ Open…   (⌘O)   •   .xsc transcriptions open too")
                .font(.callout)
                .foregroundStyle(Palette.textSecondaryOnSurface)
            Button("Open…") { model.openPanel() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.openPanel() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.openAny(url: url) }
            }
            return true
        }
    }
}

// MARK: - Header bar (in-content toolbar — like the original's wxWidgets toolbar)
// Glass control clusters with morphing active states. The Fx button is pinned with
// layout priority so it can never be clipped at narrow window sizes; at very narrow
// widths the fit buttons compress away (ViewThatFits) before anything else breaks.

struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Namespace private var glassNS

    var body: some View {
        ViewThatFits(in: .horizontal) {
            barContent(includeFit: true)
            barContent(includeFit: false)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func barContent(includeFit: Bool) -> some View {
        HStack(spacing: 8) {
            GlassEffectContainer(spacing: 2) {
                HStack(spacing: 2) {
                    headerButton("Open a sound file or .xsc transcription", "folder", caption: "Open") { model.openPanel() }
                    headerButton("Save transcription as an .xsc file", "square.and.arrow.down",
                                 caption: "Save", disabled: model.doc.fileInfo == nil) { model.save() }
                }
            }

            if includeFit {
                GlassEffectContainer(spacing: 2) {
                    HStack(spacing: 2) {
                        headerButton("Zoom the selection to fill the window", "rectangle.compress.vertical",
                                     caption: "Fit Sel", disabled: !model.doc.hasSelection) {
                            model.fitSelection(animated: true)
                        }
                        headerButton("Zoom the whole file into view", "rectangle.expand.vertical",
                                     caption: "Fit All", disabled: model.doc.fileInfo == nil) {
                            model.fitWholeFile(animated: true)
                        }
                    }
                }
            }

            GlassEffectContainer(spacing: 2) {
                HStack(spacing: 2) {
                    headerButton("Loop A-B — press A to set the loop start, A again at the end", "repeat",
                                 caption: "Loop A-B") {
                        model.loopAB()
                    }
                    let karaokeOn = model.doc.fx.mixActive && model.doc.fx.mixMode == .karaoke
                    headerButton(karaokeOn ? "Karaoke mixing on — click to bypass" : "Mono/Karaoke mixing",
                                 karaokeOn ? "waveform.path.badge.minus" : "waveform.path",
                                 caption: karaokeOn ? "Karaoke" : "Mono",
                                 active: karaokeOn) {
                        withMotion {
                            model.doc.fx.mixActive = !karaokeOn
                            model.doc.fx.mixMode = !karaokeOn ? .karaoke : .stereo
                            model.applyFX()
                        }
                    }
                }
            }

            // Speed presets — glass pills with a morphing selection (Liquid Glass
            // segmented-control pattern: one glassEffectID slides between pills).
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach([100.0, 70, 50, 35], id: \.self) { pct in
                        let selected = (model.doc.fx.speed == pct)
                        Button {
                            model.setSpeed(pct)
                        } label: {
                            Text(String(Int(pct)))
                                .font(.system(size: 11, design: .rounded).weight(selected ? .bold : .regular))
                                .frame(width: 30, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .modifier(GlassChip(
                            interactive: true,
                            tint: selected ? .accentColor.opacity(0.85) : nil,
                            cornerRadius: 7))
                        .glassEffectID(selected ? "speed-selected" : "speed-\(Int(pct))", in: glassNS)
                        .help("Speed \(Int(pct))%")
                        .accessibilityLabel("Speed \(Int(pct)) percent")
                    }
                }
            }

            Spacer(minLength: 8)
                .layoutPriority(1)

            Button {
                openWindow(id: "fx")
            } label: {
                Label("Fx", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .layoutPriority(2)
            .fixedSize()
            .help("Audio Effects and Controls (speed, tuning, EQ, mono/karaoke)")
            .accessibilityLabel("Audio Effects and Controls")
        }
    }

    private func headerButton(_ help: String, _ icon: String, caption: String,
                              disabled: Bool = false, active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .frame(width: 30, height: 22)
                Text(caption)
                    .font(.system(size: 7.5))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(active ? Color.accentColor : Color.primary)
        .disabled(disabled)
        .modifier(GlassChip(interactive: !disabled, tint: active ? .accentColor.opacity(0.5) : nil,
                             cornerRadius: 8))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Motion vocabulary for Lento (apple-design: damping 1.0 default, bounce only where
/// momentum/state change reads as physical; emil: nothing keyboard-driven animates).
enum LentoSpring {
    static let ui = Animation.spring(response: 0.3, dampingFraction: 1.0)
    static let bouncy = Animation.spring(response: 0.38, dampingFraction: 0.75)
}

/// Runs a bouncy spring animation unless the user has Reduce Motion enabled
/// (HIG 11.3 — substitute, don't just remove).
@MainActor
func withMotion(_ body: () -> Void) {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        body()
    } else {
        withAnimation(LentoSpring.bouncy, body)
    }
}

// MARK: - Marker zone (triangles + labels; drag to move, double-click to edit/create)

struct MarkerZoneView: View {
    @Environment(AppModel.self) private var model
    @Binding var editingMarker: Marker?
    @State private var dragging: Marker?
    @State private var dragStartTime: TimeInterval = 0
    @State private var hoveredMarker: UUID?
    @State private var pulseID = UUID()

    var body: some View {
        GeometryReader { geo in
            let g = WaveGeom(width: Double(geo.size.width), viewStart: model.viewStart, viewEnd: model.viewEnd)
            ZStack {
                Canvas { ctx, size in
                    var bg = Path()
                    bg.addRect(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5))
                    ctx.fill(bg, with: .color(Palette.surfaceEdge))

                    for m in model.doc.markersSorted() {
                        let x = g.x(for: m.position)
                        guard x >= -20, x <= size.width + 20 else { continue }
                        let hovered = (hoveredMarker == m.id)
                        var tri = Path()
                        let base = size.height - 2
                        let s: CGFloat = hovered ? 1.25 : 1.0
                        tri.move(to: CGPoint(x: x - 5 * s, y: base))
                        tri.addLine(to: CGPoint(x: x + 5 * s, y: base))
                        tri.addLine(to: CGPoint(x: x, y: base - 10 * s))
                        tri.closeSubpath()
                        ctx.fill(tri, with: .color(Palette.color(for: m.kind).opacity(hovered ? 1.0 : 0.92)))
                        if !m.label.isEmpty {
                            ctx.draw(Text(m.label)
                                        .font(.system(size: 10, weight: hovered ? .semibold : .medium))
                                        .foregroundStyle(Palette.textOnSurface),
                                     at: CGPoint(x: x, y: 7))
                        }
                    }
                }

                // Springy pop when a marker is placed (apple-design: bounce only where
                // the interaction carried energy — a deliberate placement action).
                if let pos = model.doc.lastMarkerAddedAt {
                    let x = g.x(for: pos)
                    if x >= -10, x <= Double(geo.size.width) + 10 {
                        MarkerPlacementPulse(id: pulseID)
                            .frame(width: 22, height: 22)
                            .position(x: x, y: geo.size.height - 7)
                            .transition(.opacity)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoveredMarker = model.doc.markersSorted()
                        .first { abs(g.x(for: $0.position) - Double(point.x)) < 7 }?.id
                case .ended:
                    hoveredMarker = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let t = g.t(forX: Double(value.location.x))
                    if dragging == nil {
                        dragging = model.doc.markersSorted()
                            .first { abs(g.x(for: $0.position) - Double(value.location.x)) < 6 }
                        dragStartTime = t
                    }
                    if let dm = dragging {
                        let newPos = max(0, dm.position + (t - dragStartTime))
                        model.doc.moveMarker(dm, to: newPos)
                    }
                }
                .onEnded { _ in dragging = nil }
            )
            .onTapGesture(count: 2) { location in
                let t = g.t(forX: Double(location.x))
                editingMarker = Marker(kind: .section, position: t, autoLabel: true, label: "", subdivision: 0)
            }
            .onTapGesture(count: 1) { location in
                if let m = model.doc.markersSorted()
                    .first(where: { abs(g.x(for: $0.position) - Double(location.x)) < 6 }) {
                    editingMarker = m
                }
            }
            .contextMenu {
                Button("New Section Marker here") {
                    model.doc.addMarker(.section, at: model.markerInsertPoint)
                }
                Button("New Measure Marker here") {
                    model.doc.addMarker(.measure, at: model.markerInsertPoint)
                }
                Button("New Beat Marker here") {
                    model.doc.addMarker(.beat, at: model.markerInsertPoint)
                }
                Divider()
                if let nearest = model.doc.markersSorted()
                    .min(by: { abs($0.position - model.markerInsertPoint) < abs($1.position - model.markerInsertPoint) }),
                   abs(nearest.position - model.markerInsertPoint) < 2.0 {
                    Button("Edit Nearest Marker…") { editingMarker = nearest }
                    Button("Delete Nearest Marker", role: .destructive) { model.doc.deleteMarker(nearest) }
                }
                Divider()
                Button("Compute Tempo") { model.computeTempoAction() }
            }
            .onChange(of: model.doc.lastMarkerAddedAt) { _, newValue in
                if newValue != nil { pulseID = UUID() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    if model.doc.lastMarkerAddedAt == newValue {
                        withAnimation(LentoSpring.ui) { model.doc.lastMarkerAddedAt = nil }
                    }
                }
            }
        }
    }
}

/// One-shot ring burst for a freshly placed marker.
private struct MarkerPlacementPulse: View {
    let id: UUID
    @State private var shown = false

    var body: some View {
        Circle()
            .stroke(Palette.markerMeasure, lineWidth: 2)
            .scaleEffect(shown ? 1.0 : 0.3)
            .opacity(shown ? 0 : 0.8)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { shown = true }
            }
            .id(id)
    }
}

// MARK: - Text zone

struct TextZoneView: View {
    @Environment(AppModel.self) private var model
    @Binding var editingBlock: TextBlock?

    var body: some View {
        GeometryReader { geo in
            let g = WaveGeom(width: Double(geo.size.width), viewStart: model.viewStart, viewEnd: model.viewEnd)
            ZStack(alignment: .topLeading) {
                Palette.surface.opacity(0.6).ignoresSafeArea()
                ForEach(model.doc.textBlocks) { block in
                    let x = g.x(for: block.position)
                    if x > -block.widthPx && x < Double(geo.size.width) {
                        Text(block.text.isEmpty ? "…" : block.text)
                            .font(.system(size: 10))
                            .lineLimit(4)
                            .padding(4)
                            .frame(width: block.widthPx, alignment: .leading)
                            .background(Palette.blockColor(block.colorIndex).opacity(0.22))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.blockColor(block.colorIndex).opacity(0.7)))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .position(x: x + block.widthPx / 2, y: 14 + Double(block.verticalRow % 2) * 20)
                            .onTapGesture { editingBlock = block }
                    }
                }
            }
        }
        .clipped()
    }
}

// MARK: - Waveform

struct WaveformView: View {
    @Environment(AppModel.self) private var model
    @State private var hoverX: Double?

    var body: some View {
        ZStack {
            WaveCanvas()
            WheelCatcher { delta, cmd in
                if cmd {
                    model.zoomHoriz(factor: delta > 0 ? 1.2 : 1 / 1.2)
                } else {
                    let dt = -delta * model.doc.secondsVisible / 400
                    model.scrollBy(dt)
                }
            }
            // Hover readout: hairline + time, in a small glass chip (Q7).
            if let x = hoverX, let width = GeometryTracker.width {
                let g = WaveGeom(width: width, viewStart: model.viewStart, viewEnd: model.viewEnd)
                let t = g.t(forX: x)
                Rectangle()
                    .fill(Palette.tickLine)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .position(x: x, y: 0)
                    .ignoresSafeArea()
                Text(TimeFormat.short(t))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.textOnSurface)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .modifier(GlassChip(interactive: false, cornerRadius: 6))
                    .position(x: min(max(x, 34), width - 34), y: 14)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoverX = Double(point.x)
            case .ended: hoverX = nil
            }
        }
        .contextMenu {
            Button("Play from Current Point") { model.play() }
            Button("Play from Here") { model.play(from: hoverPoint()) }
            Divider()
            Button("Loop A-B here") { model.loopAB() }
            Divider()
            Button("Fit Selection") { model.fitSelection(animated: true) }
            Button("Fit Whole File") { model.fitWholeFile(animated: true) }
            Divider()
            Button("New Section Marker at Current Point") { model.addMarker(.section) }
            Button("New Measure Marker at Current Point") { model.addMarker(.measure) }
            Button("New Beat Marker at Current Point") { model.addMarker(.beat) }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    GeometryTracker.last = value.startLocation
                    let t = time(at: value.location.x)
                    model.doc.setSelection(from: time(at: value.startLocation.x), to: t)
                }
                .onEnded { value in
                    let dist = hypot(value.translation.width, value.translation.height)
                    if dist < 4 {
                        let t = time(at: value.location.x)
                        model.doc.hasSelection = false
                        model.doc.currentPoint = t
                        // Click-to-seek: while playing, jump playback to the clicked
                        // point too (like the original's responsive scrubbing).
                        if model.audio.isPlaying || model.audio.isPaused {
                            model.audio.seek(to: t)
                            model.audio.playingPoint = t
                        }
                    }
                }
        )
        .gesture(
            DragGesture(minimumDistance: 0).modifiers(.command)
                .onEnded { value in
                    // Play from clicked point without changing current point or selection.
                    let t = time(at: value.location.x)
                    model.play(from: t)
                }
        )
        .onTapGesture(count: 2) { location in
            let t = time(at: location.x)
            model.doc.hasSelection = false
            model.doc.currentPoint = t
            model.play(from: t)
        }
    }

    private func hoverPoint() -> TimeInterval {
        guard let x = hoverX else { return model.viewStart }
        return time(at: x)
    }

    private func time(at x: CGFloat) -> TimeInterval {
        guard let width = GeometryTracker.width else { return model.viewStart }
        let g = WaveGeom(width: Double(width), viewStart: model.viewStart, viewEnd: model.viewEnd)
        return g.t(forX: Double(x))
    }
}

enum GeometryTracker {
    static var width: Double?
    static var last: CGPoint?
}

struct WaveCanvas: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Canvas { ctx, size in
            GeometryTracker.width = Double(size.width)
            let g = WaveGeom(width: Double(size.width), viewStart: model.viewStart, viewEnd: model.viewEnd)
            let dur = model.doc.fileInfo?.duration ?? 0

            // Background
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.surface))

            // Grid: light second ticks
            if model.doc.showTimeLine {
                drawTimeTicks(ctx: ctx, g: g, size: size)
            }

            // Waveform
            let midY = size.height / 2
            let isStereo = model.audio.channels > 1 && !model.doc.displayAsMono
            let peaks = model.audio.peaks(from: model.viewStart, to: model.viewEnd, count: Int(size.width))
            for (i, p) in peaks.enumerated() {
                let x = Double(i)
                if isStereo {
                    // Left channel above center, right below (as the original displays stereo)
                    let lh = CGFloat(p.max) * (midY - 6) * CGFloat(model.doc.verticalZoom)
                    let rmax = CGFloat(p.max) * (midY - 6) * CGFloat(model.doc.verticalZoom)
                    var leftPath = Path()
                    leftPath.move(to: CGPoint(x: x, y: midY - 2))
                    leftPath.addLine(to: CGPoint(x: x, y: midY - 2 - min(lh, midY - 4)))
                    ctx.stroke(leftPath, with: .color(Palette.wave), lineWidth: 1)
                    var rightPath = Path()
                    rightPath.move(to: CGPoint(x: x, y: midY + 3))
                    rightPath.addLine(to: CGPoint(x: x, y: midY + 3 + min(rmax, midY - 4)))
                    ctx.stroke(rightPath, with: .color(Palette.waveDim), lineWidth: 1)
                } else {
                    let h = CGFloat(p.max) * (midY - 6) * CGFloat(model.doc.verticalZoom)
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: midY - min(h, midY - 4)))
                    path.addLine(to: CGPoint(x: x, y: midY + min(h, midY - 4)))
                    ctx.stroke(path, with: .color(Palette.wave), lineWidth: 1)
                }
            }

            // dB lines
            if model.doc.showDBLines {
                for db in stride(from: -10.0, through: -70.0, by: -10.0) {
                    let frac = pow(10.0, db / 20.0)
                    let y = midY - CGFloat(frac) * (midY - 6) * CGFloat(model.doc.verticalZoom)
                    if y > 4 {
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(p, with: .color(Palette.tickLine.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        ctx.draw(Text("\(Int(db))dB").font(.system(size: 8)).foregroundStyle(Palette.tickText),
                                 at: CGPoint(x: 22, y: y - 7))
                    }
                }
            }

            // Selection highlight
            if let sel = model.doc.selection {
                let x0 = g.x(for: sel.lowerBound)
                let x1 = g.x(for: sel.upperBound)
                var rect = Path()
                rect.addRect(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height))
                ctx.fill(rect, with: .color(Palette.selection))
                var l0 = Path(); l0.move(to: CGPoint(x: x0, y: 0)); l0.addLine(to: CGPoint(x: x0, y: size.height))
                var l1 = Path(); l1.move(to: CGPoint(x: x1, y: 0)); l1.addLine(to: CGPoint(x: x1, y: size.height))
                ctx.stroke(l0, with: .color(Palette.selectionEdge), lineWidth: 1)
                ctx.stroke(l1, with: .color(Palette.selectionEdge), lineWidth: 1)
            }

            // Current point: little red triangle (single) or two triangles (selection ends)
            drawCurrentPoint(ctx: ctx, g: g, size: size)

            // Play position indicator
            if model.audio.isPlaying || model.audio.isPaused {
                let x = g.x(for: model.audio.playingPoint)
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(Palette.playLine.opacity(0.9)), lineWidth: 1.5)
            }

            // Unread band placeholder is unnecessary: the whole file is in memory.
            _ = dur
        }
        .clipped()
    }

    private func drawCurrentPoint(ctx: GraphicsContext, g: WaveGeom, size: CGSize) {
        func triangle(at x: Double, up: Bool) {
            var p = Path()
            let y: CGFloat = up ? 2 : size.height - 2
            let dir: CGFloat = up ? 1 : -1
            p.move(to: CGPoint(x: x - 6, y: y))
            p.addLine(to: CGPoint(x: x + 6, y: y))
            p.addLine(to: CGPoint(x: x, y: y + 10 * dir))
            p.closeSubpath()
            ctx.fill(p, with: .color(Palette.currentPoint))
        }
        if model.doc.hasSelection {
            triangle(at: g.x(for: model.doc.selectionStart), up: true)
            triangle(at: g.x(for: model.doc.selectionEnd), up: false)
        } else {
            triangle(at: g.x(for: model.doc.currentPoint), up: true)
            triangle(at: g.x(for: model.doc.currentPoint), up: false)
        }
    }

    private func drawTimeTicks(ctx: GraphicsContext, g: WaveGeom, size: CGSize) {
        // choose tick spacing so ticks are ~80px apart
        let span = model.viewEnd - model.viewStart
        let targetTicks = max(2, Int(size.width / 80))
        var step = span / Double(targetTicks)
        let niceSteps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        step = niceSteps.first { $0 >= step } ?? 600
        var t = (model.viewStart / step).rounded(.up) * step
        while t <= model.viewEnd {
            let x = g.x(for: t)
            var p = Path()
            p.move(to: CGPoint(x: x, y: size.height - 10))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(Palette.tickLine), lineWidth: 0.5)
            let label = t < 3600 ? TimeFormat.short(t) : String(format: "%.0f:%02.0f", t / 60, t.truncatingRemainder(dividingBy: 60))
            ctx.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.tickText),
                     at: CGPoint(x: x, y: size.height - 16))
            t += step
        }
    }
}

/// NSView that forwards scroll-wheel events so the waveform scrolls/zooms like the original.
struct WheelCatcher: NSViewRepresentable {
    var onWheel: (_ deltaY: Double, _ cmd: Bool) -> Void

    func makeNSView(context: Context) -> WheelView {
        let v = WheelView()
        v.onWheel = onWheel
        return v
    }
    func updateNSView(_ nsView: WheelView, context: Context) {
        nsView.onWheel = onWheel
    }

    final class WheelView: NSView {
        var onWheel: ((Double, Bool) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            let cmd = event.modifierFlags.contains(.command)
            onWheel?(Double(event.scrollingDeltaY), cmd)
        }
    }
}

// MARK: - Custom scroll bar with play position (as in the original)

struct ScrollBarView: View {
    @Environment(AppModel.self) private var model
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let g = WaveGeom(width: Double(geo.size.width), viewStart: 0, viewEnd: model.doc.fileInfo?.duration ?? 1)
            Canvas { ctx, size in
                // track
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.tickLine.opacity(0.2)))
                // thumb
                let x0 = g.x(for: model.viewStart)
                let x1 = g.x(for: model.viewEnd)
                var thumb = Path()
                thumb.addRect(CGRect(x: x0, y: 2, width: max(8, x1 - x0), height: size.height - 4))
                ctx.fill(thumb, with: .color(Palette.tickLine.opacity(0.7)))
                // play position
                if model.audio.isPlaying || model.audio.isPaused {
                    let xp = g.x(for: model.audio.playingPoint)
                    var p = Path()
                    p.move(to: CGPoint(x: xp, y: 0))
                    p.addLine(to: CGPoint(x: xp, y: size.height))
                    ctx.stroke(p, with: .color(Palette.wave), lineWidth: 1.5)
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let t = g.t(forX: Double(v.location.x))
                if dragging {
                    model.scrollTo(center: t)
                } else if abs(v.translation.width) > 2 {
                    dragging = true
                    model.scrollTo(center: t)
                } else {
                    model.scrollTo(center: t)
                }
            }.onEnded { _ in dragging = false })
        }
    }
}

// MARK: - Navigation bar (whole-file overview with markers)

struct NavigationBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let g = WaveGeom(width: Double(geo.size.width), viewStart: 0, viewEnd: model.doc.fileInfo?.duration ?? 1)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.tickLine.opacity(0.12)))
                // selection as a thin line along the top edge
                if let sel = model.doc.selection {
                    var p = Path()
                    p.addRect(CGRect(x: g.x(for: sel.lowerBound), y: 0,
                                     width: max(1, g.x(for: sel.upperBound) - g.x(for: sel.lowerBound)), height: 2))
                    ctx.fill(p, with: .color(Palette.currentPoint))
                }
                // section + measure markers
                for m in model.doc.markersSorted() where m.kind != .beat {
                    let x = g.x(for: m.position)
                    guard x >= 0, x <= size.width else { continue }
                    var p = Path()
                    p.move(to: CGPoint(x: x - 3, y: size.height))
                    p.addLine(to: CGPoint(x: x + 3, y: size.height))
                    p.addLine(to: CGPoint(x: x, y: size.height - 7))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(Palette.color(for: m.kind).opacity(m.kind == .section ? 1 : 0.55)))
                    if m.kind == .section, !m.label.isEmpty {
                        ctx.draw(Text(m.label).font(.system(size: 8, weight: .medium)).foregroundStyle(Palette.tickText),
                                 at: CGPoint(x: min(max(x, 10), size.width - 10), y: 7))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let t = g.t(forX: Double(location.x))
                model.scrollTo(center: t)
            }
        }
    }
}

// MARK: - Splitter between waveform and spectrum

struct SplitterBar: View {
    @Binding var fraction: Double
    var body: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.6))
            .overlay {
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { _ in
                        Circle().fill(.secondary.opacity(0.5)).frame(width: 3, height: 3)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture().onChanged { v in
                    let screenH = NSScreen.main?.visibleFrame.height ?? 800
                    fraction = min(0.85, max(0.15, fraction - v.translation.height / screenH))
                }
            )
    }
}

// MARK: - Marker edit sheet

struct MarkerEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let marker: Marker
    @State private var kind: MarkerKind = .section
    @State private var label: String = ""
    @State private var autoLabel = true
    @State private var subdivision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Marker").font(.headline)
            Picker("Type", selection: $kind) {
                Text("Section").tag(MarkerKind.section)
                Text("Measure").tag(MarkerKind.measure)
                Text("Beat").tag(MarkerKind.beat)
            }
            .pickerStyle(.segmented)
            TextField("Label", text: $label)
                .textFieldStyle(.roundedBorder)
            Toggle("Label automatically", isOn: $autoLabel)
            Stepper("Subdivisions (0 = same as previous, 1 = none)", value: $subdivision, in: 0...16)
            Text("Position: \(TimeFormat.short(marker.position))")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Delete") {
                    model.doc.deleteMarker(marker)
                    dismiss()
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    var m = marker
                    m.kind = kind
                    m.autoLabel = autoLabel
                    m.label = label
                    m.subdivision = subdivision
                    model.doc.updateMarker(m)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            kind = marker.kind
            label = marker.label
            autoLabel = marker.autoLabel
            subdivision = marker.subdivision
        }
    }
}

// MARK: - Text block edit sheet

struct TextBlockEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let block: TextBlock
    @State private var text: String = ""
    @State private var colorIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Text Block").font(.headline)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(width: 340, height: 140)
                .border(Color(nsColor: .separatorColor))
            Picker("Color", selection: $colorIndex) {
                ForEach(0..<Palette.blockColors.count, id: \.self) { i in
                    Text("Color \(i + 1)").tag(i)
                }
            }
            Text("Position: \(TimeFormat.short(block.position))").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Delete") {
                    model.doc.deleteTextBlock(block)
                    dismiss()
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    var b = block
                    b.text = text
                    b.colorIndex = colorIndex
                    if let i = model.doc.textBlocks.firstIndex(where: { $0.id == b.id }) {
                        model.doc.textBlocks[i] = b
                        model.doc.modified = true
                    } else {
                        model.doc.textBlocks.append(b)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            text = block.text
            colorIndex = block.colorIndex
        }
    }
}
