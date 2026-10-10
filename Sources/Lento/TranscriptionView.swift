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
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.12)     // opaque analysis surface
    static let surfaceEdge = Color.white.opacity(0.08)
    static let wave = Color(red: 1.0, green: 0.62, blue: 0.04)          // amber waveform (matches the original's orange)
    static let waveDim = Color(red: 1.0, green: 0.62, blue: 0.04).opacity(0.55)
    static let selection = Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.25)
    static let selectionEdge = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let currentPoint = Color(red: 1.0, green: 0.27, blue: 0.23)  // the little red triangle
    static let playLine = Color.white
    static let markerSection = Color(red: 0.48, green: 0.61, blue: 1.0)
    static let markerMeasure = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let markerBeat = Color(white: 0.75)
    static let spectrum = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let textOnSurface = Color.white.opacity(0.92)
    static let textSecondaryOnSurface = Color.white.opacity(0.45)

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
                    .frame(height: 40)
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
        .navigationTitle(model.doc.xscURL?.lastPathComponent ?? model.doc.fileInfo?.url.lastPathComponent ?? "Lento")
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

// MARK: - Header bar (in-content toolbar — like the original's wxWidgets toolbar;
// avoids the beta's broken NSToolbar menu-form path entirely)

struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            HeaderGroup {
                headerButton("Open", "folder") { model.openPanel() }
                headerButton("Save", "square.and.arrow.down", disabled: model.doc.fileInfo == nil) { model.save() }
            }
            HeaderGroup {
                headerButton("Fit Selection", "rectangle.compress.vertical", disabled: !model.doc.hasSelection) { model.fitSelection() }
                headerButton("Fit Whole File", "rectangle.expand.vertical", disabled: model.doc.fileInfo == nil) { model.fitWholeFile() }
            }
            HeaderGroup {
                headerButton("Loop A-B", "repeat") { model.loopAB() }
                let karaokeOn = model.doc.fx.mixActive && model.doc.fx.mixMode == .karaoke
                headerButton(karaokeOn ? "Karaoke on" : "Mono/Karaoke",
                             karaokeOn ? "waveform.path.badge.minus" : "waveform.path") {
                    model.doc.fx.mixActive = !karaokeOn
                    model.doc.fx.mixMode = !karaokeOn ? .karaoke : .stereo
                    model.applyFX()
                }
            }
            // Speed presets
            HeaderGroup {
                ForEach([100.0, 70, 50, 35], id: \.self) { pct in
                    Button {
                        model.setSpeed(pct)
                    } label: {
                        Text(String(Int(pct)))
                            .font(.system(size: 11, design: .rounded).weight(model.doc.fx.speed == pct ? .bold : .regular))
                            .frame(width: 26, height: 20)
                            .background(
                                model.doc.fx.speed == pct
                                    ? Palette.selectionEdge.opacity(0.35)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Speed \(Int(pct))%")
                }
            }
            Spacer()
            Button {
                openWindow(id: "fx")
            } label: {
                Label("Fx", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .help("Audio Effects and Controls")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func headerButton(_ label: String, _ icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 28, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(label)
    }
}

struct HeaderGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }
}

// MARK: - Marker zone (triangles + labels; drag to move, double-click to edit/create)

struct MarkerZoneView: View {
    @Environment(AppModel.self) private var model
    @Binding var editingMarker: Marker?
    @State private var dragging: Marker?
    @State private var dragStartTime: TimeInterval = 0

    var body: some View {
        GeometryReader { geo in
            let g = WaveGeom(width: Double(geo.size.width), viewStart: model.viewStart, viewEnd: model.viewEnd)
            Canvas { ctx, size in
                var bg = Path()
                bg.addRect(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5))
                ctx.fill(bg, with: .color(Palette.surfaceEdge))

                for m in model.doc.markersSorted() {
                    let x = g.x(for: m.position)
                    guard x >= -20, x <= size.width + 20 else { continue }
                    var tri = Path()
                    let base = size.height - 2
                    tri.move(to: CGPoint(x: x - 5, y: base))
                    tri.addLine(to: CGPoint(x: x + 5, y: base))
                    tri.addLine(to: CGPoint(x: x, y: base - 10))
                    tri.closeSubpath()
                    ctx.fill(tri, with: .color(Palette.color(for: m.kind)))
                    if !m.label.isEmpty {
                        ctx.draw(Text(m.label).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.textOnSurface),
                                 at: CGPoint(x: x, y: 7))
                    }
                }
            }
            .contentShape(Rectangle())
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
        }
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
                        ctx.stroke(p, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        ctx.draw(Text("\(Int(db))dB").font(.system(size: 8)).foregroundStyle(.white.opacity(0.3)),
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
            ctx.stroke(p, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
            let label = t < 3600 ? TimeFormat.short(t) : String(format: "%.0f:%02.0f", t / 60, t.truncatingRemainder(dividingBy: 60))
            ctx.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.4)),
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
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.white.opacity(0.05)))
                // thumb
                let x0 = g.x(for: model.viewStart)
                let x1 = g.x(for: model.viewEnd)
                var thumb = Path()
                thumb.addRect(CGRect(x: x0, y: 2, width: max(8, x1 - x0), height: size.height - 4))
                ctx.fill(thumb, with: .color(Color.white.opacity(0.18)))
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
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.white.opacity(0.03)))
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
                        ctx.draw(Text(m.label).font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.55)),
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
