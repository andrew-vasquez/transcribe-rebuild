import SwiftUI
import AppKit

// MARK: - Lower toolbar: transport controls, sliders with captions, time readouts.
// Glass chips + active states; keyboard-driven state stays instant (no animation on
// spacebar play etc.) — motion is reserved for pointer/menu-driven changes.

struct LowerBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            // Horizontal scale — captioned ("little titles" per HIG label affordance)
            CaptionedSlider(caption: "Zoom", help: "Horizontal zoom — ⌘-wheel or slider") {
                Slider(value: Binding(
                    get: { model.doc.secondsVisible },
                    set: { model.doc.secondsVisible = $0; model.clampView() }
                ), in: 1...max(2, model.doc.fileInfo?.duration ?? 60))
                .frame(width: 100)
            }

            // Volume + compression red bar (the original shows the compressor as a red bar)
            CaptionedSlider(caption: "Vol", help: "Volume — keys − and = (red bar = compression)") {
                VStack(spacing: 2) {
                    Slider(value: Binding(
                        get: { model.doc.fx.volume },
                        set: { model.doc.fx.volume = $0; model.applyFX() }
                    ), in: 0...200)
                    .frame(width: 84)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(Color.red)
                                .frame(width: min(geo.size.width,
                                                  geo.size.width * model.audio.redLevel / 12))
                        }
                    }
                    .frame(height: 3)
                }
            }

            LowerTimeBox(title: "Now Playing",
                         color: Palette.textOnSurface,
                         text: TimeFormat.short(model.audio.isPlaying || model.audio.isPaused ? model.audio.playingPoint : 0),
                         editable: false)
            LowerTimeBox(title: "Track Length",
                         color: Palette.wave,
                         text: TimeFormat.short(model.doc.fileInfo?.duration ?? 0),
                         editable: false)

            // Transport buttons
            GlassEffectContainer(spacing: 3) {
                HStack(spacing: 3) {
                    LowerBarButton(icon: "backward.end.fill", help: "Go to start") { model.goToStart() }
                    LowerBarButton(icon: "backward.fill", help: "Review — skip back (R)") { model.review() }
                    Button {
                        model.spaceToggle()
                    } label: {
                        Image(systemName: model.audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 32, height: 26)
                    }
                    .buttonStyle(.glassProminent)
                    .symbolEffect(.bounce, value: model.audio.isPlaying)
                    .disabled(model.doc.fileInfo == nil)
                    .help("Play / Pause — spacebar")
                    .accessibilityLabel(model.audio.isPlaying ? "Pause" : "Play")
                    LowerBarButton(icon: "stop.fill", help: "Stop — . (period)") { model.stopPlayback() }
                    LowerBarButton(icon: "forward.fill", help: "Cue — skip forward (C)") { model.cue() }
                    LowerBarButton(icon: "forward.end.fill", help: "Go to end") { model.goToEnd() }
                }
            }

            // Loop mode — glass chip with a visible on-state
            Button {
                withAnimation(reduceMotion ? nil : LentoSpring.bouncy) {
                    model.doc.loopMode.toggle()
                    model.applyFX()
                }
            } label: {
                Image(systemName: "repeat")
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.doc.loopMode ? Color.white : Color.primary)
            .modifier(GlassChip(interactive: true,
                                tint: model.doc.loopMode ? .accentColor.opacity(0.85) : nil,
                                cornerRadius: 8))
            .help("Loop mode — ⌘L (loops the selection when one exists)")
            .accessibilityLabel(model.doc.loopMode ? "Loop on" : "Loop off")

            // Speed slider (20–100% like the original's lower toolbar)
            CaptionedSlider(caption: "Speed \(Int(model.doc.fx.speed))%", help: "Speed — presets in the header, ⌘1–⌘4") {
                Slider(value: Binding(
                    get: { min(max(model.doc.fx.speed, 20), 100) },
                    set: { model.setSpeed(max($0, 20)) }
                ), in: 20...100)
                .frame(width: 96)
            }

            // Pitch (semitones) — the caption shows the true total including cents/octaves
            CaptionedSlider(caption: String(format: "Pitch %+.2f st", model.doc.fx.tuningCentsTotal / 100),
                            help: "Pitch in semitones — cents & octaves in the Fx window") {
                Slider(value: Binding(
                    get: { Double(model.doc.fx.semitones) },
                    set: { model.doc.fx.semitones = Int($0.rounded()); model.applyFX() }
                ), in: -12...12, step: 1)
                .frame(width: 84)
            }

            LowerTimeBox(title: "Current Point",
                         color: Palette.currentPoint,
                         text: TimeFormat.short(model.doc.currentPoint),
                         editable: true) { newValue in
                if let t = TimeFormat.parse(newValue) { model.doc.currentPoint = t }
            }
            LowerTimeBox(title: "Selection",
                         color: Palette.selectionEdge,
                         text: model.doc.hasSelection
                            ? TimeFormat.short(model.doc.selectionEnd - model.doc.selectionStart)
                            : "0:00.0",
                         editable: true) { newValue in
                if let t = TimeFormat.parse(newValue), let sel = model.doc.selection {
                    model.doc.setSelection(from: sel.lowerBound, to: sel.lowerBound + t)
                }
            }

            // Status toast — springs in, fades out (transient feedback, not a delay)
            StatusToast(message: model.statusMessage)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)   // native floating bar material (Liquid Glass on macOS 26)
    }
}

/// A caption + control group — the "little titles" that name each function.
struct CaptionedSlider<Content: View>: View {
    var caption: String
    var help: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .center, spacing: 1) {
            content
            Text(caption)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(caption)
    }
}

struct LowerBarButton: View {
    var icon: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .modifier(GlassChip(interactive: true, cornerRadius: 7))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct LowerTimeBox: View {
    var title: String
    var color: Color
    var text: String
    var editable: Bool
    var onCommit: (String) -> Void = { _ in }

    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        VStack(spacing: 1) {
            if !editing {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(minWidth: 50)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if editable {
                            draft = text
                            editing = true
                        }
                    }
            } else {
                TextField("time", text: $draft)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(minWidth: 50)
                    .onSubmit { onCommit(draft); editing = false }
                    .onExitCommand { editing = false }
            }
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .modifier(GlassChip(interactive: editable, cornerRadius: 6))
        .help(editable ? "\(title) — click to type a time (m:ss)" : title)
        .accessibilityLabel("\(title): \(text)")
    }
}

/// Transient status message: springs in, quietly fades away.
struct StatusToast: View {
    var message: String
    @State private var shown = false

    var body: some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: 180, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .modifier(GlassChip(interactive: false, cornerRadius: 8))
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.95)
            .frame(maxWidth: shown ? 180 : 0, maxHeight: shown ? 40 : 0)
            .animation(nil, value: shown)
            .onChange(of: message) { _, new in
                guard !new.isEmpty else { return }
                withAnimation(LentoSpring.bouncy) { shown = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation(LentoSpring.ui) { shown = false }
                }
            }
    }
}
