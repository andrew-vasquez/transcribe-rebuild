import Foundation
import AppKit
import AVFoundation

/// The application coordinator: one document + the audio system, plus every
/// user-initiated command (menus, keyboard shortcuts, UI controls all call into here).
@MainActor
@Observable
final class AppModel {
    let audio = AudioSystem()
    var doc = TranscriptionDocument()
    var spectrum: SpectrumResult?
    var spectrumSourceLabel = ""
    var liveSpectrum = false
    var statusMessage = ""
    var fxWindowOpen = false

    // Scroll-follow ("Scroll" on the Play menu)
    var scrollFollow = true

    private var liveTimer: Timer?

    init() {
        doc.loadEqPresetsFromDefaults()
        doc.ensureLoopSlots()
        audio.onPlayEnded = { [weak self] in
            DispatchQueue.main.async { self?.handlePlayEnded() }
        }
    }

    // MARK: - Time ↔ view mapping

    var viewStart: TimeInterval {
        doc.scrollCenter - doc.secondsVisible / 2
    }
    var viewEnd: TimeInterval {
        doc.scrollCenter + doc.secondsVisible / 2
    }

    func clampView() {
        let dur = doc.fileInfo?.duration ?? 0
        doc.secondsVisible = min(max(doc.secondsVisible, 0.1), max(dur, 0.1))
        doc.scrollCenter = min(max(doc.scrollCenter, doc.secondsVisible / 2), max(dur - doc.secondsVisible / 2, doc.secondsVisible / 2))
    }

    func scrollTo(center: TimeInterval) {
        doc.scrollCenter = center
        clampView()
    }

    func scrollBy(_ dt: TimeInterval) {
        scrollTo(center: doc.scrollCenter + dt)
    }

    func zoomHoriz(factor: Double) {
        doc.secondsVisible /= factor
        clampView()
    }

    // MARK: - File opening

    func openSoundFile(url: URL) {
        NSLog("TR-DBG openSoundFile %@", url.path)
        do {
            try audio.load(url: url)
            doc = TranscriptionDocument()
            doc.fileInfo = SoundFileInfo(url: url, sampleRate: audio.sampleRate,
                                         channels: audio.channels, frames: Int(audio.duration * AudioSystem.canonicalRate),
                                         formatName: audio.formatName)
            doc.loadEqPresetsFromDefaults()
            doc.ensureLoopSlots()
            doc.secondsVisible = min(30, doc.fileInfo!.duration)
            doc.scrollCenter = doc.secondsVisible / 2
            applyFX()
            statusMessage = "Opened \(url.lastPathComponent)"
            addRecentFile(url)
        } catch {
            statusMessage = "Cannot open: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    func openXSC(url: URL) {
        NSLog("TR-DBG openXSC %@", url.path)
        do {
            let parsed = try XSC.parse(at: url)
            guard let soundPath = parsed.soundPath else {
                statusMessage = "No sound file referenced in \(url.lastPathComponent)"
                return
            }
            var soundURL = URL(fileURLWithPath: soundPath)
            if !FileManager.default.isReadableFile(atPath: soundPath) {
                // The original looks next to the xsc; do the same.
                let guess = url.deletingLastPathComponent().appendingPathComponent((soundPath as NSString).lastPathComponent)
                if FileManager.default.isReadableFile(atPath: guess.path) {
                    soundURL = guess
                } else {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.message = "Transcribe Rebuilt couldn't find the sound file for this transcription. Please locate it."
                    if panel.runModal() == .OK, let chosen = panel.url { soundURL = chosen } else { return }
                }
            }
            openSoundFile(url: soundURL)
            doc.markers = parsed.markers
            doc.textBlocks = parsed.textBlocks
            doc.loops = parsed.loops
            doc.fx = parsed.fx
            doc.xscURL = url
            doc.modified = false
            if let cp = parsed.currentPoint { doc.currentPoint = cp }
            doc.recomputeAutoLabels()
            applyFX()
            statusMessage = "Opened transcription \(url.lastPathComponent)"
            addRecentFile(url)
        } catch {
            statusMessage = "Cannot open transcription: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    func openAny(url: URL) {
        if url.pathExtension.lowercased() == "xsc" { openXSC(url: url) }
        else { openSoundFile(url: url) }
    }

    func save() {
        if let url = doc.xscURL {
            try? XSC.write(doc: doc, to: url)
            doc.modified = false
            statusMessage = "Saved \(url.lastPathComponent)"
        } else {
            saveAs()
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = (doc.fileInfo?.url.lastPathComponent ?? "untitled") + ".xsc"
        panel.allowedFileTypes = ["xsc"]
        if panel.runModal() == .OK, let url = panel.url {
            doc.xscURL = url
            save()
        }
    }

    private func addRecentFile(_ url: URL) {
        var recent = UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []
        recent.removeAll { $0 == url.path }
        recent.insert(url.path, at: 0)
        if recent.count > 16 { recent.removeLast(recent.count - 16) }
        UserDefaults.standard.set(recent, forKey: "recentFiles")
    }

    var recentFiles: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }
    }

    // MARK: - FX → audio graph

    func applyFX() {
        audio.applyFX(doc.fx, markers: doc.markers, loopMode: doc.loopMode)
        audio.setClicks(on: doc.clicksOn, volume: doc.clickVolume, markers: doc.markers)
        audio.displayAsMono = doc.displayAsMono
        doc.modified = true
        refreshSpectrum()
    }

    // MARK: - Transport

    /// Where playback should begin: selection start if any, else current point.
    var playStart: TimeInterval { doc.selection?.lowerBound ?? doc.currentPoint }
    var playEnd: TimeInterval { doc.selection?.upperBound ?? doc.fileInfo?.duration ?? 0 }

    func play(from start: TimeInterval? = nil) {
        guard doc.fileInfo != nil else { return }
        let s = start ?? playStart
        let loopRange = doc.loopMode && doc.hasSelection ? (doc.selection!.lowerBound, doc.selection!.upperBound) : nil
        audio.play(from: s, loop: loopRange, loopMode: doc.loopMode, loopDelayTenths: doc.loopDelayTenths)
        syncTransportUI()
        startLiveSpectrum()
    }

    func pausePlayback() { audio.pause(); syncTransportUI() }
    func resumePlayback() { audio.resume(); syncTransportUI(); startLiveSpectrum() }

    func stopPlayback() {
        audio.stopPlayback()
        syncTransportUI()
    }

    /// Spacebar: play / pause / resume.
    func spaceToggle() {
        if audio.isPlaying { pausePlayback() }
        else if audio.isPaused { resumePlayback() }
        else { play() }
    }

    func pauseToggle() {
        // comma: pause/unpause
        if audio.isPaused { resumePlayback() } else { pausePlayback() }
    }

    private func handlePlayEnded() {
        syncTransportUI()
        doc.isPlaying = false
    }

    func syncTransportUI() {
        doc.isPlaying = audio.isPlaying
        doc.isPaused = audio.isPaused
    }

    /// Jump while keeping transport state (Cue/Review v1 behavior).
    func cue() { seekTo(audio.playingPoint + 5) }
    func review() { seekTo(audio.playingPoint - 5) }

    func seekTo(_ t: TimeInterval) {
        guard doc.fileInfo != nil else { return }
        let clamped = min(max(t, 0), doc.fileInfo!.duration)
        if audio.isPlaying || audio.isPaused {
            audio.seek(to: clamped)
            audio.playingPoint = clamped
        } else {
            doc.currentPoint = clamped
        }
        if scrollFollow, audio.isPlaying { scrollTo(center: clamped) }
    }

    func goToStart() { seekTo(playStart) }
    func goToEnd() { seekTo(doc.fileInfo?.duration ?? 0) }

    // MARK: - Live spectrum

    func startLiveSpectrum() {
        guard liveSpectrum else { return }
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.audio.isPlaying else { return }
            self.refreshSpectrum()
        }
    }

    func refreshSpectrum() {
        guard doc.fileInfo != nil, doc.showSpectrum else { spectrum = nil; return }

        // Snapshot every @Observable read ON MAIN — observation tracking must never
        // run on a background thread (it races SwiftUI's AttributeGraph bookkeeping).
        let selection = doc.selection
        let playingPoint = audio.playingPoint
        let isPlaying = audio.isPlaying
        let eqActive = doc.fx.eqActive
        let eqGains = doc.fx.eqGains
        let tuningCents = doc.fx.tuningCentsTotal
        let noteGuessing = doc.showNoteGuesses
        let chordGuessing = doc.showChordGuesses
        let monoWindow = audio.monoWindow  // nonisolated; lock-guarded internals

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let center: TimeInterval
            let length: Int
            let label: String
            if let sel = selection, sel.upperBound - sel.lowerBound > 0.02 {
                let span = min(sel.upperBound - sel.lowerBound, SpectrumAnalyzer.maxSelectionWindow)
                center = sel.lowerBound + span / 2
                length = Int(span * AudioSystem.canonicalRate)
                label = "Selection"
            } else {
                center = playingPoint
                length = Int(SpectrumAnalyzer.pointWindow * AudioSystem.canonicalRate)
                label = isPlaying ? "Playing point" : "Point"
            }
            guard length >= 1024 else { return }
            let mono = monoWindow(center - Double(length) / 2 / AudioSystem.canonicalRate, length)
            let pitchFactor = pow(2.0, tuningCents / 1200.0)
            let result = SpectrumAnalyzer.analyze(mono: mono, sampleRate: AudioSystem.canonicalRate,
                                                  label: label, atSeconds: center,
                                                  eqActive: eqActive, eqGains: eqGains,
                                                  pitchFactor: pitchFactor,
                                                  noteGuessing: noteGuessing,
                                                  chordGuessing: chordGuessing)
            DispatchQueue.main.async {
                self?.spectrum = result
                self?.spectrumSourceLabel = label
            }
        }
    }

    // MARK: - Markers (S/M/B keyboard semantics: place at paused/playing point, else current point)

    var markerInsertPoint: TimeInterval {
        if audio.isPlaying || audio.isPaused { return audio.playingPoint }
        return doc.currentPoint
    }

    func addMarker(_ kind: MarkerKind) {
        guard doc.fileInfo != nil else { return }
        doc.addMarker(kind, at: markerInsertPoint)
        audio.setClicks(on: doc.clicksOn, volume: doc.clickVolume, markers: doc.markers)
    }

    func deleteMarkersInSelection() {
        guard doc.selection != nil else { return }
        doc.deleteMarkers(in: doc.selection!)
    }

    func computeTempoAction() {
        if let t = doc.computeTempo() {
            statusMessage = String(format: "Tempo: %.1f bpm (altered speed: %.1f bpm)", t.bpmOriginal, t.bpmAltered)
        } else {
            statusMessage = "Compute Tempo needs a selection containing at least two markers, one per beat."
        }
    }

    // MARK: - Stored loops

    func storeLoop(_ i: Int) { doc.storeLoop(i) }
    func recallLoop(_ i: Int) {
        doc.recallLoop(i)
        scrollTo(center: doc.currentPoint)
    }

    // MARK: - Loop A-B (A key: first press start, second press end → loop)

    var loopABHalf: TimeInterval?

    func loopAB() {
        guard doc.fileInfo != nil else { return }
        let p = audio.isPlaying || audio.isPaused ? audio.playingPoint : doc.currentPoint
        if let start = loopABHalf {
            if p > start {
                doc.setSelection(from: start, to: p)
                doc.loopMode = true
                loopABHalf = nil
                audio.setLoopRange((start, p))
                play(from: start)
                statusMessage = "Loop A-B set"
            } else {
                loopABHalf = p
            }
        } else {
            loopABHalf = p
            statusMessage = "Loop start set — press A again at the loop end"
        }
    }

    // MARK: - Selection commands (keyboard)

    func selectionMoveLeft(by dt: TimeInterval) {
        if doc.hasSelection {
            doc.selectionStart = max(0, doc.selectionStart - dt)
            doc.currentPoint = doc.selectionStart
        } else {
            doc.currentPoint = max(0, doc.currentPoint - dt)
        }
    }

    func selectionMoveRight(by dt: TimeInterval) {
        if doc.hasSelection {
            doc.selectionEnd = min(doc.fileInfo?.duration ?? 0, doc.selectionEnd + dt)
        } else {
            doc.currentPoint = min(doc.fileInfo?.duration ?? 0, doc.currentPoint + dt)
        }
    }

    func selectionIncreaseLeft(by dt: TimeInterval) {
        if doc.hasSelection { doc.selectionStart = max(0, doc.selectionStart - dt); doc.currentPoint = doc.selectionStart }
        else { doc.setSelection(from: doc.currentPoint, to: doc.currentPoint + dt) }
    }

    func selectionDecreaseLeft(by dt: TimeInterval) {
        if doc.hasSelection { doc.selectionStart = min(doc.selectionEnd - 0.01, doc.selectionStart + dt); doc.currentPoint = doc.selectionStart }
    }

    func selectionIncreaseRight(by dt: TimeInterval) {
        if doc.hasSelection { doc.selectionEnd = min(doc.fileInfo?.duration ?? 0, doc.selectionEnd + dt) }
        else { doc.setSelection(from: doc.currentPoint, to: doc.currentPoint + dt) }
    }

    func selectionDecreaseRight(by dt: TimeInterval) {
        if doc.hasSelection { doc.selectionEnd = max(doc.selectionStart + 0.01, doc.selectionEnd - dt) }
    }

    /// J/K/L: instant short selection centered on the playing point.
    func quickSelection(_ tenths: Double) {
        guard doc.fileInfo != nil else { return }
        let p = audio.isPlaying || audio.isPaused ? audio.playingPoint : doc.currentPoint
        doc.setSelection(from: p - tenths / 20, to: p + tenths / 20)
        if !audio.isPlaying { play() }
    }

    /// D: select from current point to the playing point.
    func selectCurrentToPlaying() {
        let p = audio.isPlaying || audio.isPaused ? audio.playingPoint : doc.currentPoint
        doc.setSelection(from: min(doc.currentPoint, p), to: max(doc.currentPoint, p))
    }

    func moveCurrentPoint(behind seconds: Double) {
        let p = audio.isPlaying || audio.isPaused ? audio.playingPoint : doc.currentPoint
        doc.currentPoint = max(0, p - seconds)
    }

    // MARK: - Speed presets (toolbar + Cmd-1..4)

    func setSpeed(_ pct: Double) {
        doc.fx.speed = min(max(pct, 5), 200)
        applyFX()
    }

    func nudgeSpeed(_ delta: Double) {
        setSpeed(doc.fx.speed + delta)
    }

    // MARK: - Tempo sync helpers

    func markersNear(_ t: TimeInterval, count: Int) -> [Marker] {
        doc.markersSorted().filter { abs($0.position - t) < 600 }
            .prefix(count).map { $0 }
    }

    func jumpToMarker(_ direction: Int, kinds: Set<MarkerKind>) {
        let sorted = doc.markersSorted().filter { kinds.contains($0.kind) }
        guard !sorted.isEmpty else { return }
        let p = audio.isPlaying || audio.isPaused ? audio.playingPoint : (doc.hasSelection ? doc.selection!.upperBound : doc.currentPoint)
        var target: Marker?
        if direction < 0 {
            target = sorted.last { $0.position < p - 0.001 }
        } else {
            target = sorted.first { $0.position > p + 0.001 }
        }
        if let m = target {
            seekTo(m.position)
            scrollTo(center: m.position)
        }
    }
}
