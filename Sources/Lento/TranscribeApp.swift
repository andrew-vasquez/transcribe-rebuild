import SwiftUI
import AppKit

@main
struct LentoApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Lento") {
            TranscriptionView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    KeyCatcherWindowAdapter.shared.model = model
                    KeyCatcherWindowAdapter.shared.install()
                    // Defer the launch file open past the first layout transaction.
                    DispatchQueue.main.async {
                        openCommandLineFileIfNeeded()
                    }
                }
                .background(KeyCatcherView())
        }
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Lento") { AboutPanel.show(model: model) }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.doc.undo.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.doc.undo.canUndo)
                Button("Redo") { model.doc.undo.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.doc.undo.canRedo)
            }
            CommandGroup(replacing: .help) {
                Button("Lento Help") {
                    NSWorkspace.shared.open(URL(string: "https://www.seventhstring.com/xscribe/overview.html")!)
                }
                Divider()
                Button("Rebuild Notes (evidence & roadmap)") {
                    let p = URL(fileURLWithPath: #filePath)
                        .deletingLastPathComponent()      // Sources/Lento
                        .deletingLastPathComponent()      // Sources
                        .deletingLastPathComponent()      // repo root
                        .appendingPathComponent("README.md")
                    NSWorkspace.shared.open(p)
                }
            }

            // Merge file commands into the system File menu
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Import Sound File…") { model.importSoundFilePanel() }
                Button("Export Sound File…") { model.exportSoundFilePanel() }
                Button("Export Markers and Text Blocks…") { model.exportMarkersPanel() }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu("Play") {
                Button("Play Selection — space") { model.play() }
                Button("Stop — .") { model.stopPlayback() }
                Button("Pause — ,") { model.pauseToggle() }
                Divider()
                Toggle("Loop", isOn: Binding(get: { model.doc.loopMode }, set: { model.doc.loopMode = $0; model.applyFX() }))
                    .keyboardShortcut("l", modifiers: .command)
                Toggle("Scroll", isOn: Binding(get: { model.scrollFollow }, set: { model.scrollFollow = $0 }))
                    .keyboardShortcut("r", modifiers: .command)
                Toggle("Clicks", isOn: Binding(get: { model.doc.clicksOn }, set: { model.doc.clicksOn = $0; model.applyFX() }))
            }

            CommandMenu("Markers") {
                Button("New Section Marker — S") { model.addMarker(.section) }
                Button("New Measure Marker — M") { model.addMarker(.measure) }
                Button("New Beat Marker — B") { model.addMarker(.beat) }
                Divider()
                Button("Delete Selected Markers") { model.deleteMarkersInSelection() }
                Button("Equally Space Selected Markers") { model.doc.equallySpaceMarkers() }
                Divider()
                Button("Compute Tempo") { model.computeTempoAction() }
            }

            // Merge view commands into the system View menu
            CommandGroup(replacing: .toolbar) {
                Toggle("Navigation Bar", isOn: Binding(get: { model.doc.showNavigationBar }, set: { model.doc.showNavigationBar = $0 }))
                Toggle("Show Spectrum", isOn: Binding(get: { model.doc.showSpectrum }, set: { model.doc.showSpectrum = $0; model.refreshSpectrum() }))
                Toggle("Show Note Guesses", isOn: Binding(get: { model.doc.showNoteGuesses }, set: { model.doc.showNoteGuesses = $0; model.refreshSpectrum() }))
                Toggle("Show Chord Guesses", isOn: Binding(get: { model.doc.showChordGuesses }, set: { model.doc.showChordGuesses = $0; model.refreshSpectrum() }))
                Toggle("Show dB Lines", isOn: Binding(get: { model.doc.showDBLines }, set: { model.doc.showDBLines = $0 }))
                Toggle("Show Time Line", isOn: Binding(get: { model.doc.showTimeLine }, set: { model.doc.showTimeLine = $0 }))
                Toggle("Display as Mono", isOn: Binding(get: { model.doc.displayAsMono }, set: { model.doc.displayAsMono = $0; model.applyFX() }))
                Divider()
                Button("Fit Selection") { model.fitSelection() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Fit Whole File") { model.fitWholeFile() }
                    .keyboardShortcut("g", modifiers: .command)
                Divider()
                Button("Zoom In") { model.zoomHoriz(factor: 1.5) }
                Button("Zoom Out") { model.zoomHoriz(factor: 1 / 1.5) }
                Button("Vertical Zoom In") { model.doc.verticalZoom *= 1.25 }
                Button("Vertical Zoom Out") { model.doc.verticalZoom /= 1.25 }
            }

            CommandMenu("Text") {
                Toggle("Show Text Zone", isOn: Binding(get: { model.doc.showTextZone }, set: { model.doc.showTextZone = $0 }))
                Divider()
                Button("New Text Block — T") { model.doc.addTextBlock(at: model.markerInsertPoint) }
            }

            // Merge into the system Window menu
            CommandGroup(after: .windowList) {
                Divider()
                Button("Audio Effects and Controls") { openWindow(id: "fx") }
            }
        }

        // Floating glass FX window — a proper inspector palette (macOS 15+ UtilityWindow):
        // floats above main windows, follows key-window focus, dismissible with Escape.
        UtilityWindow("Audio Effects", id: "fx") {
            FXPanelView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        // Native Settings scene (provides the standard ⌘, menu item).
        Settings {
            PreferencesView(model: model)
        }
    }
}

// MARK: - App delegate: receive files opened via Launch Services (double-click, `open -a app file`)

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    /// Files delivered at launch, before the SwiftUI window connected to this delegate.
    var pendingLaunchURLs: [URL] = []
    private var handled = Set<String>()

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard handled.insert(url.path).inserted else { continue }
            if let model {
                DispatchQueue.main.async { model.openAny(url: url) }
            } else {
                pendingLaunchURLs.append(url)
            }
        }
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        self.application(application, open: filenames.map { URL(fileURLWithPath: $0) })
    }
}

// MARK: - Keyboard shortcut map (the original's kb.htm defaults)
//
// Called from KeyCatcherNSView via the responder chain. A focused text field
// (or any other first responder) consumes keys before this is ever reached.

extension AppModel {
    /// Returns true when the event was consumed by a shortcut.
    @discardableResult
    func handleKeyEvent(_ event: NSEvent, isKeyUp: Bool) -> Bool {
        // Cmd-combos are handled by menu accelerators.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) { return false }

        let ch = (event.charactersIgnoringModifiers ?? "").lowercased()

        if isKeyUp {
            switch ch {
            case "z", ";":
                if audio.isPlaying { pausePlayback() }
                return true
            default:
                return false
            }
        }

        let hasShift = modifiers.contains(.shift)
        let hasOpt = modifiers.contains(.option)
        let step: TimeInterval = 0.1

        switch ch {
        case " ": spaceToggle(); return true
        case ".": stopPlayback(); return true
        case ",": pauseToggle(); return true
        case "c": cue(); return true
        case "r": review(); return true
        case "o": seekTo(audio.playingPoint - 0.25); return true
        case "p": seekTo(audio.playingPoint + 0.25); return true
        case "a": loopAB(); return true
        case "z": play(); return true
        case ";": play(); return true
        case "-": doc.fx.volume = max(0, doc.fx.volume - 5); applyFX(); return true
        case "=": doc.fx.volume = min(200, doc.fx.volume + 5); applyFX(); return true
        case "s": addMarker(.section); return true
        case "m": addMarker(.measure); return true
        case "b": addMarker(.beat); return true
        case "t": doc.addTextBlock(at: markerInsertPoint); return true
        case "e":
            if audio.isPlaying || audio.isPaused { doc.currentPoint = audio.playingPoint }
            return true
        case "d": selectCurrentToPlaying(); return true
        case "j": quickSelection(1); return true
        case "k": quickSelection(2); return true
        case "l": quickSelection(3); return true
        case "u": doc.collapseSelectionToLeft(); return true
        case "i":
            if doc.hasSelection { doc.hasSelection = false; doc.currentPoint = doc.selectionEnd }
            return true
        case "1": moveCurrentPoint(behind: 10); return true
        case "2": moveCurrentPoint(behind: 5); return true
        case "3": moveCurrentPoint(behind: 2); return true
        case "4": moveCurrentPoint(behind: 1); return true
        case "q": scrollTo(center: doc.currentPoint); return true
        case "w": scrollTo(center: audio.playingPoint); return true
        default: break
        }

        switch event.keyCode {
        case 36: // Enter: resume / pause
            if audio.isPaused { resumePlayback() } else if audio.isPlaying { pausePlayback() }
            return true
        case 123: // ← : enlarge at left (Shift: reduce at right)
            if hasShift { selectionDecreaseRight(by: 0.05) } else { selectionIncreaseLeft(by: 0.05) }
            return true
        case 124: // → : reduce at left (Shift: enlarge at right)
            if hasShift { selectionIncreaseRight(by: 0.05) } else { selectionDecreaseLeft(by: 0.05) }
            return true
        case 125: // ↓ : small scroll to the right
            scrollBy(doc.secondsVisible / 10)
            return true
        case 126: // ↑ : small scroll to the left
            scrollBy(-doc.secondsVisible / 10)
            return true
        case 116: // PageUp
            scrollBy(-doc.secondsVisible * 0.9)
            return true
        case 121: // PageDown
            scrollBy(doc.secondsVisible * 0.9)
            return true
        case 115: // Home
            scrollTo(center: 0)
            return true
        case 119: // End
            scrollTo(center: doc.fileInfo?.duration ?? 0)
            return true
        case 33: // [
            if hasOpt { jumpToMarker(-1, kinds: [.section]) }
            else if modifiers.contains(.control) { jumpToMarker(-1, kinds: [.measure, .section]) }
            else if hasShift { jumpToMarker(-1, kinds: [.section, .measure, .beat]) }
            else { selectionMoveLeft(by: step) }
            return true
        case 35: // ]
            if hasOpt { jumpToMarker(1, kinds: [.section]) }
            else if modifiers.contains(.control) { jumpToMarker(1, kinds: [.measure, .section]) }
            else if hasShift { jumpToMarker(1, kinds: [.section, .measure, .beat]) }
            else { selectionMoveRight(by: step) }
            return true
        default:
            return false
        }
    }
}

// MARK: - Command-line file opening (as the original supports)

extension LentoApp {
    /// The original can load a file given on the command line; so can we.
    /// Handles both argv paths and files delivered via Launch Services at launch.
    fileprivate func openCommandLineFileIfNeeded() {
        guard !didOpenLaunchFile else { return }
        didOpenLaunchFile = true

        let delegate = appDelegate as? AppDelegate
        delegate?.model = model

        var urls: [URL] = []
        for arg in CommandLine.arguments.dropFirst() {
            let u = URL(fileURLWithPath: arg)
            if FileManager.default.isReadableFile(atPath: arg) { urls.append(u) }
        }
        urls.append(contentsOf: delegate?.pendingLaunchURLs ?? [])
        delegate?.pendingLaunchURLs = []
        NSLog("TR-DEBUG: launch urls=%@", urls.map { $0.lastPathComponent })
        if let first = urls.first {
            model.openAny(url: first)
            for extra in urls.dropFirst() { model.openAny(url: extra) }
        }
    }
}

private var didOpenLaunchFile = false

// MARK: - Keyboard shortcuts via the responder chain (kb.htm default map)
//
// The original NSEvent-local-monitor approach tripped a beta over-release in
// AppKit's event handling (bogus free of an NSEvent at autorelease-pool pop).
// Receiving keys through the responder chain never touches event delivery, and
// gives the correct behavior for free: when a text field (or the FX window) has
// focus, it consumes keys first.

@MainActor
final class KeyCatcherWindowAdapter {
    static let shared = KeyCatcherWindowAdapter()
    var model: AppModel?

    /// Makes the key-catcher view the window's first responder when no other
    /// responder (text field, etc.) already has focus.
    func install() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        if window.firstResponder is KeyCatcherNSView { return }
        if let catcher = window.contentView?.subviews.compactMap({ $0 as? KeyCatcherNSView }).first {
            window.makeFirstResponder(catcher)
        }
    }
}

struct KeyCatcherView: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyCatcherNSView {
        KeyCatcherNSView()
    }
    func updateNSView(_ nsView: KeyCatcherNSView, context: Context) {}
}

final class KeyCatcherNSView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window?.firstResponder == nil || window?.firstResponder is NSWindow {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if let model = KeyCatcherWindowAdapter.shared.model,
           model.handleKeyEvent(event, isKeyUp: false) {
            return // consumed by a shortcut
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if let model = KeyCatcherWindowAdapter.shared.model,
           model.handleKeyEvent(event, isKeyUp: true) {
            return
        }
        super.keyUp(with: event)
    }
}