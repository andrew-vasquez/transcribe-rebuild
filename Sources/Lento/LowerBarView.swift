import SwiftUI
import AppKit

// MARK: - Lower toolbar: transport controls, sliders, and time boxes
// Mirrors the original's lower toolbar, grouped into a glass control bar.

struct LowerBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            // Horizontal scale slider
            Slider(value: Binding(
                get: { model.doc.secondsVisible },
                set: { model.doc.secondsVisible = $0; model.clampView() }
            ), in: 1...max(2, model.doc.fileInfo?.duration ?? 60))
            .frame(width: 110)
            .help("Horizontal zoom")

            // Volume + compression red bar (the original shows the compressor as a red bar)
            VStack(spacing: 2) {
                Slider(value: Binding(
                    get: { model.doc.fx.volume },
                    set: { model.doc.fx.volume = $0; model.applyFX() }
                ), in: 0...200)
                .frame(width: 90)
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: min(geo.size.width, geo.size.width * model.audio.redLevel / 12))
                        }
                }
                .frame(height: 3)
            }
            .help("Volume (− / =)")

            // Now playing / Track length
            LowerTimeBox(title: "Now Playing",
                         color: Palette.textOnSurface,
                         text: TimeFormat.short(model.audio.isPlaying || model.audio.isPaused ? model.audio.playingPoint : 0),
                         editable: false)
            LowerTimeBox(title: "Track Length",
                         color: Palette.wave,
                         text: TimeFormat.short(model.doc.fileInfo?.duration ?? 0),
                         editable: false)

            // Transport buttons
            HStack(spacing: 2) {
                LowerBarButton(icon: "backward.end.fill", help: "Go to start") { model.goToStart() }
                LowerBarButton(icon: "backward.fill", help: "Review (skip back)") { model.review() }
                LowerBarButton(icon: model.audio.isPlaying ? "pause.fill" : "play.fill",
                               primary: true,
                               help: "Play / Pause (space)") { model.spaceToggle() }
                LowerBarButton(icon: "stop.fill", help: "Stop (.)") { model.stopPlayback() }
                LowerBarButton(icon: "forward.fill", help: "Cue (skip forward)") { model.cue() }
                LowerBarButton(icon: "forward.end.fill", help: "Go to end") { model.goToEnd() }
                Toggle(isOn: Binding(get: { model.doc.loopMode }, set: { model.doc.loopMode = $0; model.applyFX() })) {
                    Label("Loop", systemImage: "repeat")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Loop mode (⌘L)")
            }

            // Speed slider (20–100% like the original's lower toolbar)
            VStack(spacing: 1) {
                Slider(value: Binding(
                    get: { min(max(model.doc.fx.speed, 20), 100) },
                    set: { model.setSpeed(max($0, 20)) }
                ), in: 20...100)
                .frame(width: 110)
                Text("\(Int(model.doc.fx.speed))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .help("Speed (⌘1..⌘4 presets)")

            // Pitch (semitones) slider with the true total displayed
            VStack(spacing: 1) {
                Slider(value: Binding(
                    get: { Double(model.doc.fx.semitones) },
                    set: { model.doc.fx.semitones = Int($0.rounded()); model.applyFX() }
                ), in: -12...12, step: 1)
                .frame(width: 90)
                Text(String(format: "%+.2f st", model.doc.fx.tuningCentsTotal / 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .help("Pitch in semitones (cents & octaves in the Fx window)")

            // Current point / Selection length (editable)
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

            // Always present (constant layout structure; empty when no message)
            Text(model.statusMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
                .help(model.statusMessage)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)   // native floating bar material (Liquid Glass on macOS 26)
    }
}

struct LowerBarButton: View {
    var icon: String
    var primary = false
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 28, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .foregroundStyle(primary ? Color.white : .primary)
        .background {
            if primary {
                Capsule().fill(Color.accentColor)
            }
        }
        .clipShape(Capsule())
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
                    .frame(minWidth: 52)
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
                    .frame(minWidth: 52)
                    .onSubmit { onCommit(draft); editing = false }
                    .onExitCommand { editing = false }
            }
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
    }
}
