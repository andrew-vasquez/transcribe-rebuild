import SwiftUI
import AppKit
import AVFoundation

// MARK: - AppModel: file panels & view fitting

extension AppModel {
    func openPanel() {
        NSLog("TR-DBG openPanel")
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Open a sound file to start a new transcription, or an existing .xsc transcription."
        panel.allowedContentTypes = [.audio, .movie, UTType(filenameExtension: "xsc")].compactMap { $0 }
        if let recent = recentFiles.first { panel.directoryURL = recent.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { openAny(url: url) }
    }

    func importSoundFilePanel() {
        NSLog("TR-DBG importSoundFilePanel")
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            openSoundFile(url: url)
            statusMessage = "Imported sound file \(url.lastPathComponent)"
        }
    }

    func fitSelection() {
        guard let sel = doc.selection, sel.upperBound > sel.lowerBound else { statusMessage = "Fit Selection needs a selection"; return }
        doc.secondsVisible = sel.upperBound - sel.lowerBound
        doc.scrollCenter = (sel.upperBound + sel.lowerBound) / 2
        clampView()
    }

    func fitWholeFile() {
        guard let dur = doc.fileInfo?.duration, dur > 0 else { return }
        doc.secondsVisible = dur
        doc.scrollCenter = dur / 2
        clampView()
    }

    func exportSoundFilePanel() {
        guard doc.fileInfo != nil else { statusMessage = "Load a sound file first"; return }
        let sheet = ExportSheet()
        sheet.run(model: self)
    }
    func exportMarkersPanel() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["txt"]
        panel.nameFieldStringValue = (doc.fileInfo?.url.deletingPathExtension().lastPathComponent ?? "markers") + ".txt"
        if panel.runModal() == .OK, let url = panel.url {
            var out = "Time\tType\tLabel\n"
            let df = DateFormatter()
            df.dateFormat = "mm:ss.SSS"
            for m in doc.markersSorted() {
                out += "\(df.string(from: Date(timeIntervalSince1970: m.position)))\t\(m.kind.rawValue)\t\(m.label)\n"
            }
            for b in doc.textBlocks.sorted(by: { $0.position < $1.position }) {
                let t = df.string(from: Date(timeIntervalSince1970: b.position))
                out += "\(t)\tT\t\(b.text.replacingOccurrences(of: "\n", with: " ⏎ "))\n"
            }
            try? out.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported markers & text to \(url.lastPathComponent)"
        }
    }
}

// MARK: - WAV export sheet (whole file / selection, N repetitions, effects applied)

@MainActor
final class ExportSheet: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    func run(model: AppModel) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Export Sound File"
        p.delegate = self
        let view = ExportSheetView { source, reps, applyEffects in
            let save = NSSavePanel()
            save.allowedFileTypes = ["wav"]
            save.nameFieldStringValue = (model.doc.fileInfo?.url.deletingPathExtension().lastPathComponent ?? "export") + ".wav"
            if save.runModal() == .OK, let url = save.url {
                // Snapshot all @Observable reads on main before hopping to a background queue.
                let fx = model.doc.fx
                let selection = model.doc.selection
                let audioData = model.audio.audioData
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = ExportWAV.render(data: audioData, fx: fx, selection: selection,
                                               to: url, source: source, repetitions: reps, applyEffects: applyEffects)
                    DispatchQueue.main.async {
                        model.statusMessage = ok ? "Exported \(url.lastPathComponent)" : "Export failed"
                    }
                }
            }
            p.close()
        }
        p.contentView = NSHostingView(rootView: view)
        p.center()
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
}

enum ExportSource: String, CaseIterable {
    case wholeFile = "Whole file"
    case selection = "Current selection"
}

struct ExportSheetView: View {
    var onExport: (ExportSource, Int, Bool) -> Void

    @State private var source: ExportSource = .wholeFile
    @State private var reps = 1
    @State private var applyEffects = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Sound File").font(.headline)
            Picker("Source", selection: $source) { ForEach(ExportSource.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.radioGroup)
            Stepper("Repetitions: \(reps)", value: $reps, in: 1...99)
            Toggle("Apply current audio effects", isOn: $applyEffects)
            HStack {
                Spacer()
                Button("Export…") { onExport(source, reps, applyEffects) }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { onExport(source, 0, applyEffects) }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

// MARK: - Offline WAV export through an offline AVAudioEngine graph

enum ExportWAV {
    /// Renders whole file or selection (×repetitions) through the current FX chain to a 16-bit WAV.
    /// All inputs are snapshots captured on the main thread — no @Observable access happens here.
    static func render(data: AudioData?, fx: FxState, selection: ClosedRange<TimeInterval>?,
                       to url: URL, source: ExportSource, repetitions: Int, applyEffects: Bool) -> Bool {
        guard let data else { return false }

        let range: ClosedRange<Int>
        switch source {
        case .wholeFile:
            range = 0...data.frameCount
        case .selection:
            if let sel = selection {
                range = AudioSystem.frame(forSeconds: sel.lowerBound)...AudioSystem.frame(forSeconds: sel.upperBound)
            } else {
                range = 0...data.frameCount
            }
        }
        let start = max(0, range.lowerBound)
        let end = min(data.frameCount, range.upperBound)
        guard end > start else { return false }
        let totalFrames = (end - start) * max(1, repetitions)

        let format = AVAudioFormat(standardFormatWithSampleRate: AudioSystem.canonicalRate, channels: 2)!
        let engine = AVAudioEngine()
        let eq = AVAudioUnitEQ(numberOfBands: EQBands.count)
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.bandwidth = Float(EQBands.bandwidth)
            band.frequency = Float(EQBands.centers[i])
            band.gain = Float(min(max(fx.eqGains[i], -60), EQBands.maxGain))
        }
        eq.bypass = !(applyEffects && fx.eqActive)

        let varispeed = AVAudioUnitVarispeed()
        let timePitch = AVAudioUnitTimePitch()

        if applyEffects {
            let speed = min(max(fx.speed, 5), 200) / 100.0
            let tuning = fx.tuningCentsTotal
            if fx.analogLock {
                timePitch.rate = 1.0
                timePitch.pitch = 0.0
                varispeed.rate = Float(speed * pow(2.0, tuning / 1200.0))
            } else {
                let tpPitch = min(max(tuning, -2400), 2400)
                let v = pow(2.0, (tuning - Double(tpPitch)) / 1200.0)
                varispeed.rate = Float(v)
                timePitch.pitch = Float(tpPitch)
                timePitch.rate = Float(speed / v)
            }
        }

        let core = RenderCore(data: data)
        core.setPlaying(true, from: start, loop: nil, loopMode: false)
        core.update { c in
            c.mixMode = applyEffects && fx.mixActive ? fx.mixMode : .stereo
            c.mixBalance = fx.mixBalance
        }

        let sn = AVAudioSourceNode(format: format) { silence, _, frameCount, abl in
            core.render(frameCount: frameCount, abl: abl)
        }
        engine.attach(sn)
        engine.attach(eq)
        engine.attach(varispeed)
        engine.attach(timePitch)
        engine.connect(sn, to: eq, format: format)
        engine.connect(eq, to: varispeed, format: format)
        engine.connect(varispeed, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        do {
            let outFrames = AVAudioFrameCount(Double(totalFrames) / Double(timePitch.rate) / Double(varispeed.rate) + 4096)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try engine.start()

            guard let outFile = try? AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVSampleRateKey: AudioSystem.canonicalRate,
                AVNumberOfChannelsKey: 2,
            ]) else { return false }

            var rendered: AVAudioFrameCount = 0
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            while rendered < outFrames {
                let toRender = AVAudioFrameCount(min(4096, outFrames - rendered))
                let status = try engine.renderOffline(toRender, to: buf)
                switch status {
                case .success:
                    try? outFile.write(from: buf)
                    rendered += toRender
                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    return false
                case .error:
                    return false
                @unknown default:
                    return false
                }
            }
            return true
        } catch {
            NSLog("export: \(error)")
            return false
        }
    }
}

// MARK: - About panel

enum AboutPanel {
    static func show(model: AppModel) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "About Transcribe Rebuilt"
        let view = VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Transcribe Rebuilt").font(.title2.bold())
            Text("Version 1.0")
            Text("A native macOS rebuild of Seventh String's Transcribe! (9.70.1),\nbuilt from shipped-artifact evidence — see REVERSE-ENGINEERING-EVIDENCE.md.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Transcribe! is Copyright © 1998-2026 Seventh String Software.\nThis independent rebuild is for personal study.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(width: 380, height: 260)
        p.contentView = NSHostingView(rootView: view)
        p.center()
        p.makeKeyAndOrderFront(nil)
        _ = model
    }
}

// MARK: - Preferences (native Settings scene content)

struct PreferencesView: View {
    var model: AppModel
    @AppStorage("spectrumFixedScale") private var fixedScale = false
    @AppStorage("recentFilesCount") private var recentCount = 16

    var body: some View {
        Form {
            Toggle("Live Spectrum (follow playback)", isOn: Binding(get: { model.liveSpectrum }, set: {
                model.liveSpectrum = $0
                UserDefaults.standard.set($0, forKey: "liveSpectrum")
                if $0 { model.startLiveSpectrum() }
            }))
            Toggle("Fixed vertical scale for spectrum", isOn: $fixedScale)
            Toggle("Auto-scroll to follow playback", isOn: Binding(get: { model.scrollFollow }, set: { model.scrollFollow = $0 }))
            Stepper("Recent files: \(recentCount)", value: $recentCount, in: 4...32)
        }
        .padding()
        .frame(width: 360, height: 220)
    }
}
