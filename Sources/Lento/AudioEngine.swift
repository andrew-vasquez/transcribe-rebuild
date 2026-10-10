import Foundation
import AVFoundation
import CoreAudio
import os
import AppKit

// MARK: - Parameters the render thread reads (lock-guarded, held for nanoseconds)

struct RenderConfig {
    var isPlaying = false
    var readFrame: Int = 0
    var playStartFrame: Int = 0
    var loopMode = true
    var loopStartFrame: Int = 0
    var loopEndFrame: Int = 0
    var hasLoopRange = false
    var loopDelayFrames = 0
    var pendingDelayFrames = 0
    var clicksOn = false
    var clickVolume: Float = 0.6
    var markerFrames: [Int] = []
    // Mono / Karaoke mixing (applied to file channels L,R at read time)
    var mixMode: MixMode = .stereo
    var mixBalance: Double = 0
}

/// Immutable-ish audio data shared with the render thread. Written only before render starts
/// for a given file (swap = new object).
final class AudioData {
    let channels: [ContiguousArray<Float>]  // deinterleaved, canonical 44.1kHz
    let frameCount: Int
    let sampleRate: Double = 44100.0
    let click: [Float]

    init(channels: [ContiguousArray<Float>], click: [Float]) {
        self.channels = channels
        self.frameCount = channels.first?.count ?? 0
        self.click = click
    }

    var duration: TimeInterval { Double(frameCount) / sampleRate }
}

final class RenderCore {
    let data: AudioData
    private var config = RenderConfig()
    private let lock = NSLock()
    private var clickRemaining = 0
    private var nextMarkerIndex = 0

    init(data: AudioData) { self.data = data }

    // MARK: Config access (main thread)

    func update(_ mutate: (inout RenderConfig) -> Void) {
        lock.lock(); mutate(&config); lock.unlock()
    }

    var readout: RenderConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    func setPlaying(_ on: Bool, from frame: Int, loop: (start: Int, end: Int)?, loopMode: Bool) {
        lock.lock()
        config.isPlaying = on
        config.readFrame = frame
        config.playStartFrame = frame
        config.loopMode = loopMode
        if let l = loop {
            config.loopStartFrame = l.start
            config.loopEndFrame = l.end
            config.hasLoopRange = true
        } else {
            config.hasLoopRange = false
        }
        config.pendingDelayFrames = 0
        clickRemaining = 0
        resyncMarkerCursor()
        lock.unlock()
    }

    func seek(to frame: Int) {
        lock.lock()
        config.readFrame = max(0, min(frame, data.frameCount))
        // Seeking outside the active loop range breaks the loop — otherwise the next
        // render pass would snap playback straight back to the loop start, making
        // cue/review/click-to-seek feel dead while looping.
        if config.hasLoopRange,
           config.readFrame < config.loopStartFrame || config.readFrame >= config.loopEndFrame {
            config.hasLoopRange = false
        }
        clickRemaining = 0
        resyncMarkerCursor()
        lock.unlock()
    }

    func setLoopRange(_ loop: (start: Int, end: Int)?) {
        lock.lock()
        if let l = loop {
            config.loopStartFrame = l.start
            config.loopEndFrame = l.end
            config.hasLoopRange = true
        } else {
            config.hasLoopRange = false
        }
        lock.unlock()
    }

    private func resyncMarkerCursor() {
        // next marker strictly after the current read position
        let f = config.readFrame
        nextMarkerIndex = config.markerFrames.firstIndex { $0 > f } ?? config.markerFrames.count
    }

    // MARK: Render (audio thread)

    /// Reads mono-mixed pair for a frame.
    @inline(__always)
    private func mixPair(at frame: Int) -> (l: Float, r: Float) {
        let data = self.data
        let ch = data.channels
        let safeFrame = min(frame, data.frameCount - 1)
        if ch.count < 2 {
            let m = ch.first?[safeFrame] ?? 0
            return (m, m)
        }
        let l = ch[0][safeFrame]
        let r = ch[1][safeFrame]
        switch config.mixMode {
        case .stereo: return (l, r)
        case .mono:
            let m = (l + r) * 0.5
            return (m, m)
        case .left: return (l, l)
        case .right: return (r, r)
        case .karaoke:
            let k = (l - r) * Float(0.5 * (1.0 + config.mixBalance))
            return (k, k)
        }
    }

    func render(frameCount: AVAudioFrameCount, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }

        guard config.isPlaying else {
            // Render silence without advancing.
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            for buf in buffers {
                if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
            }
            return noErr
        }

        let outBuffers = UnsafeMutableAudioBufferListPointer(abl)
        let outL = outBuffers[0]
        guard let outLMem = outL.mData?.assumingMemoryBound(to: Float.self) else { return kAudioUnitErr_InvalidParameter }
        let stereo = outBuffers.count >= 2
        var outRMem: UnsafeMutablePointer<Float>? = nil
        if stereo, let r = outBuffers[1].mData?.assumingMemoryBound(to: Float.self) { outRMem = r }
        let n = Int(frameCount)

        var frame = config.readFrame
        var produced = 0
        while produced < n {
            // Loop delay: silence between repetitions
            if config.pendingDelayFrames > 0 {
                let d = min(n - produced, config.pendingDelayFrames)
                for i in 0..<d {
                    outLMem[produced + i] = 0
                    outRMem?[produced + i] = 0
                }
                produced += d
                config.pendingDelayFrames -= d
                continue
            }
            // Loop wrap
            if config.loopMode, config.hasLoopRange, frame >= config.loopEndFrame {
                frame = config.loopStartFrame
                config.readFrame = frame
                if config.loopDelayFrames > 0 { config.pendingDelayFrames = config.loopDelayFrames }
                resyncMarkerCursor()
            }
            if frame >= data.frameCount { break }
            let pair = mixPair(at: frame)
            // Metronome click at markers
            var clickAmp: Float = 0
            if config.clicksOn {
                if nextMarkerIndex < config.markerFrames.count, frame >= config.markerFrames[nextMarkerIndex] {
                    clickRemaining = data.click.count
                    nextMarkerIndex += 1
                }
                if clickRemaining > 0 {
                    clickAmp = data.click[data.click.count - clickRemaining] * config.clickVolume
                    clickRemaining -= 1
                }
            }
            outLMem[produced] = pair.l + clickAmp
            outRMem?[produced] = pair.r + clickAmp
            produced += 1
            frame += 1
        }
        // Zero any tail (end of file)
        if produced < n {
            for i in produced..<n {
                outLMem[i] = 0
                outRMem?[i] = 0
            }
            config.readFrame = data.frameCount
        } else {
            config.readFrame = frame
        }
        return noErr
    }
}

// MARK: - AudioSystem (main thread, ObservableObject)

@MainActor
@Observable
final class AudioSystem {
    static let canonicalRate: Double = 44100.0

    // Published state
    var playingPoint: TimeInterval = 0
    var isPlaying = false
    var isPaused = false
    var redLevel: Double = 0  // amount of compression indication (dB above 0 before limiting)
    var fileName: String = ""
    var filePath: String = ""
    var channels: Int = 2
    var sampleRate: Double = 44100
    var duration: TimeInterval = 0
    var fileLoaded = false
    var formatName = ""
    /// Set when a file decoded only partially (damaged/VBR/capped) — surfaced by the UI.
    var loadWarning: String?
    var onPlayEnded: (() -> Void)?

    // Graph
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let eqNode = AVAudioUnitEQ(numberOfBands: EQBands.count)
    private let varispeedNode = AVAudioUnitVarispeed()
    private let timePitchNode = AVAudioUnitTimePitch()
    /// Apple's DynamicsProcessor AudioUnit — the native macOS stand-in for the
    /// compressor/limiter the original uses to prevent digital overload.
    private var compressorNode: AVAudioUnit?
    private var compressorAttached = false
    /// True once the limiter's parameters have actually been set (factory defaults
    /// are an audible −20 dB compressor, so never route audio through it unconfigured).
    private var compressorReady = false
    private var chainAttached = false
    // Engine internals — not UI state. Ignored by observation; `nonisolated(unsafe)`
    // because `data` is immutable after load and `core` is NSLock-guarded internally.
    @ObservationIgnored nonisolated(unsafe) private(set) var core: RenderCore?
    @ObservationIgnored nonisolated(unsafe) private(set) var data: AudioData?
    private var outputFormat: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: Self.canonicalRate, channels: 2)! }
    private var displayTimer: Timer?
    private var peakTapInstalled = false

    // MARK: Lifecycle

    init() {
        setupGraph()
    }

    private func setupGraph() {
        for (i, band) in eqNode.bands.enumerated() {
            band.filterType = .parametric
            band.bandwidth = Float(EQBands.bandwidth)
            band.frequency = Float(EQBands.centers[i])
            band.bypass = false
            band.gain = 0
        }
        eqNode.bypass = true

        configureTimePitchQuality()

        instantiateDynamicsProcessor()
    }

    /// Quality tuning for the slow-down engine (AUNewTimePitch), per the SDK header:
    /// - Smoothness (param 4, 3–32, default 8): "the generated output can be made to
    ///   sound smoother by increasing the density of processing time frames… When
    ///   slowing down percussive audio, lower values may be better." Lento exists to
    ///   slow music down, so we take the percussive-friendly value 4.
    /// - Spectral Coherence (param 6, 0–1, default 1): peak locking for a less
    ///   "phasey"/reverberant sound. Pinned on explicitly.
    private func configureTimePitchQuality() {
        var raw: AudioUnit
        if #available(macOS 27.0, *) {
            raw = timePitchNode.withAudioUnit { $0 }
        } else {
            raw = timePitchNode.audioUnit
        }
        let smooth: AudioUnitParameterValue = 4.0
        let coherence: AudioUnitParameterValue = 1.0
        let s1 = AudioUnitSetParameter(raw, 4, kAudioUnitScope_Global, 0, smooth, 0)
        let s2 = AudioUnitSetParameter(raw, 6, kAudioUnitScope_Global, 0, coherence, 0)
        if s1 != noErr || s2 != noErr {
            NSLog("Lento: TimePitch quality params failed (smooth=%d coherence=%d)", s1, s2)
        }
    }

    private func instantiateDynamicsProcessor() {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        AVAudioUnit.instantiate(with: desc, options: []) { [weak self] unit, _ in
            guard let unit else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.compressorNode = unit
                self.configureDynamics(unit)
            }
        }
    }

    /// Configures the DynamicsProcessor as the original uses its compressor: a
    /// *safety limiter against digital overload*, not an audible compressor.
    ///
    /// Parameter IDs per AudioUnitParameters.h (kDynamicsProcessorParam_*):
    /// 0=Threshold(dB, −40…20, default −20!), 1=HeadRoom(dB knee), 4=AttackTime
    /// (**seconds**, 0.0001…0.2), 5=ReleaseTime(seconds), 6=OverallGain.
    /// Note: this unit has no fixed ratio parameter — HeadRoom sets the knee depth.
    /// The factory default (threshold −20 dB) audibly squashes program material —
    /// which is exactly the distortion heard on slowed-down audio before this fix.
    private func configureDynamics(_ unit: AVAudioUnit) {
        var raw: AudioUnit
        if #available(macOS 27.0, *) {
            raw = unit.withAudioUnit { $0 }
        } else {
            raw = unit.audioUnit
        }
        func setParam(_ id: AudioUnitParameterID, _ value: AudioUnitParameterValue, _ name: String) {
            let status = AudioUnitSetParameter(raw, id, kAudioUnitScope_Global, 0, value, 0)
            if status != noErr {
                NSLog("Lento: DynamicsProcessor param %@ (id %u) failed: %d", name, id, status)
            }
        }
        setParam(0, -2.0, "Threshold −2 dB")        // only engage near full scale
        setParam(1, 4.0, "HeadRoom 4 dB")           // gentle soft knee
        setParam(4, 0.001, "Attack 1 ms")           // seconds, not ms
        setParam(5, 0.08, "Release 80 ms")
        setParam(6, 0.0, "Overall gain 0 dB")
        compressorReady = true
    }

    func startEngineIfNeeded() {
        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("engine start: \(error)") }
        }
    }

    // MARK: Loading

    func load(url: URL) throws {
        stopPlayback()
        stopDisplayTimer()
        engine.stop()
        if let sn = sourceNode {
            engine.detach(sn)
            sourceNode = nil
        }

        // --- Decode. MP3s (especially VBR) often misreport their length and can
        // throw mid-stream, so we decode in chunks and keep what decodes cleanly —
        // never trusting file.length for the full read.
        let (file, srcFormat): (AVAudioFile, AVAudioFormat)
        if let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) {
            file = f; srcFormat = f.processingFormat
        } else if let f = try? AVAudioFile(forReading: url) {
            file = f; srcFormat = f.processingFormat
        } else {
            throw NSError(domain: "LentoAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This file isn't a sound file Lento can read (unknown or unsupported format)."])
        }
        let chCount = Int(srcFormat.channelCount)
        let chunkFrames: AVAudioFrameCount = 65536
        guard let chunkBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames),
              let chunkData = chunkBuf.floatChannelData else {
            throw NSError(domain: "LentoAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Not enough memory to decode this file."])
        }

        // Decode in chunks until end-of-file. AVAudioFile.length can misreport for VBR
        // MP3s (and decoders can throw mid-stream), so the loop trusts the reads, not
        // the header. Sanity cap = ~2 hours, purely to bound pathological files.
        var channelArrays = [[Float]](repeating: [], count: chCount)
        let reportedFrames = Int(file.length)
        if reportedFrames > 0 {
            let reserve = min(reportedFrames + 65536, 360_000_000)
            for c in 0..<chCount { channelArrays[c].reserveCapacity(reserve) }
        }
        let hardCapFrames = 360_000_000
        var decodedFrames = 0
        var hitCap = false
        while decodedFrames < hardCapFrames {
            chunkBuf.frameLength = 0
            do {
                try file.read(into: chunkBuf, frameCount: chunkFrames)
            } catch {
                break // decoder hit a snag mid-file (common with VBR MP3) — keep what we have
            }
            let n = Int(chunkBuf.frameLength)
            if n == 0 { break }
            if decodedFrames + n > hardCapFrames {
                hitCap = true
                break
            }
            for c in 0..<chCount {
                channelArrays[c].append(contentsOf: UnsafeBufferPointer(start: chunkData[c], count: n))
            }
            decodedFrames += n
        }
        if reportedFrames > 0 && decodedFrames < reportedFrames - Int(srcFormat.sampleRate) {
            // Decoded noticeably less than the header promised (VBR MP3 or a damaged
            // file): keep going with what we have, but say so.
            loadWarning = String(format: "Decoded %.0f of %.0f seconds — the file may be damaged or mislabelled.",
                                 Double(decodedFrames) / srcFormat.sampleRate,
                                 Double(reportedFrames) / srcFormat.sampleRate)
        } else if hitCap {
            loadWarning = "Only the first two hours were loaded."
        } else {
            loadWarning = nil
        }
        guard decodedFrames > 0 else {
            throw NSError(domain: "LentoAudio", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No decodable audio found in this file."])
        }

        // Convert per source channel to canonical 44.1 kHz
        var converted: [ContiguousArray<Float>] = []
        for c in 0..<chCount {
            converted.append(resample(ContiguousArray(channelArrays[c]),
                                      from: srcFormat.sampleRate, to: Self.canonicalRate))
        }
        channelArrays.removeAll(keepingCapacity: false)
        // Reduce to stereo
        let stereo: [ContiguousArray<Float>]
        if converted.count == 1 {
            stereo = [converted[0], converted[0]]
        } else {
            stereo = [converted[0], converted[1]]
        }

        let data = AudioData(channels: stereo, click: Self.makeClick())
        self.data = data
        self.core = RenderCore(data: data)
        self.channels = 2
        self.sampleRate = data.sampleRate
        self.duration = data.duration
        self.fileLoaded = true
        self.formatName = url.pathExtension.uppercased()
        self.fileName = url.lastPathComponent
        self.filePath = url.path

        let core = self.core!
        let format = outputFormat
        let sn = AVAudioSourceNode(format: format) { [weak core] silence, _, frameCount, abl in
            guard let core = core else {
                let buffers = UnsafeMutableAudioBufferListPointer(abl)
                for buf in buffers {
                    if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
                }
                return noErr
            }
            return core.render(frameCount: frameCount, abl: abl)
        }
        sourceNode = sn
        engine.attach(sn)
        if !chainAttached {
            engine.attach(eqNode)
            engine.attach(varispeedNode)
            engine.attach(timePitchNode)
            chainAttached = true
        }
        engine.connect(sn, to: eqNode, format: format)
        engine.connect(eqNode, to: varispeedNode, format: format)
        engine.connect(varispeedNode, to: timePitchNode, format: format)
        if let comp = compressorNode, compressorReady {
            if !compressorAttached {
                engine.attach(comp)
                compressorAttached = true
            }
            engine.connect(timePitchNode, to: comp, format: format)
            engine.connect(comp, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(timePitchNode, to: engine.mainMixerNode, format: format)
        }
        engine.prepare()
        try engine.start()

        installPeakTapIfNeeded()
        startDisplayTimer()
    }

    private func installPeakTapIfNeeded() {
        guard !peakTapInstalled else { return }
        peakTapInstalled = true
        // Real-time audio rule: no allocations and no ObjC property access in the tap.
        // Pre-read the channel count on the main thread; the tap only stores a
        // lock-guarded float; the 30Hz display timer (main) reads it.
        let channels = engine.mainMixerNode.outputFormat(forBus: 0).channelCount
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            var peak: Float = 0
            for c in 0..<Int(channels) {
                let p = ch[c]
                var i = 0
                while i < n { let v = abs(p[i]); if v > peak { peak = v }; i += 1 }
            }
            self.storePeak(peak)
        }
    }

    /// Peak level written by the real-time tap; read by the main-thread display timer.
    @ObservationIgnored
    private let peakState = OSAllocatedUnfairLock(initialState: Float(0))

    nonisolated private func storePeak(_ p: Float) {
        peakState.withLock { $0 = max($0, p) }
    }

    nonisolated private func takePeak() -> Float {
        peakState.withLock { let v = $0; $0 = 0; return v }
    }

    private func resample(_ input: ContiguousArray<Float>, from inRate: Double, to outRate: Double) -> ContiguousArray<Float> {
        if abs(inRate - outRate) < 0.5 { return input }
        let step = inRate / outRate
        let outCount = Int(Double(input.count) * outRate / inRate)
        var out = ContiguousArray<Float>(repeating: 0, count: outCount)
        for i in 0..<outCount {
            let t = Double(i) * step
            let i0 = min(Int(t), input.count - 1)
            let i1 = min(i0 + 1, input.count - 1)
            let frac = Float(t - Double(i0))
            out[i] = input[i0] * (1 - frac) + input[i1] * frac
        }
        return out
    }

    /// A short woody metronome tick (the original sampled a wooden metronome).
    static func makeClick() -> [Float] {
        let n = 1024
        var click = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / Self.canonicalRate
            let env = exp(-t * 55)
            let w = sin(2.0 * .pi * 1750.0 * t) * 0.5 + sin(2.0 * .pi * 840.0 * t) * 0.35
            let noise = (Double.random(in: -1...1)) * exp(-t * 700) * 0.3
            click[i] = Float((w * env + noise) * 0.9)
        }
        return click
    }

    // MARK: FX application

    /// Pushes the document's FX state to the graph. Call on any change.
    func applyFX(_ fx: FxState, markers: [Marker], loopMode: Bool) {
        guard let core else { return }

        // EQ
        eqNode.bypass = !fx.eqActive
        for (i, band) in eqNode.bands.enumerated() {
            band.gain = Float(min(max(fx.eqGains[i], -60), EQBands.maxGain))
        }

        // Volume (mainMixer)
        engine.mainMixerNode.volume = Float(fx.volume / 100.0)

        // Speed & tuning
        let speed = min(max(fx.speed, 5), 200) / 100.0
        let tuning = fx.tuningCentsTotal
        if fx.analogLock {
            timePitchNode.rate = 1.0
            timePitchNode.pitch = 0.0
            let v = speed * pow(2.0, tuning / 1200.0)
            varispeedNode.rate = Float(v)
        } else {
            let tpPitch = min(max(tuning, -2400), 2400)
            let extra = tuning - Double(tpPitch)
            let v = pow(2.0, extra / 1200.0)
            varispeedNode.rate = Float(v)
            timePitchNode.pitch = Float(tpPitch)
            timePitchNode.rate = Float(speed / v)
        }

        // Render config
        core.update { c in
            c.loopMode = loopMode
            c.mixMode = fx.mixActive ? fx.mixMode : .stereo
            c.mixBalance = fx.mixBalance
            c.markerFrames = markers.sorted { $0.position < $1.position }.map { Self.frame(forSeconds: $0.position) }
        }
    }

    func setClicks(on: Bool, volume: Double, markers: [Marker]) {
        core?.update { c in
            c.clicksOn = on
            c.clickVolume = Float(volume)
            c.markerFrames = markers.sorted { $0.position < $1.position }.map { Self.frame(forSeconds: $0.position) }
        }
    }

    nonisolated static func frame(forSeconds t: TimeInterval) -> Int { Int((t * canonicalRate).rounded()) }
    nonisolated static func seconds(forFrame f: Int) -> TimeInterval { Double(f) / canonicalRate }

    // MARK: Transport

    func play(from start: TimeInterval, loop loopRange: (start: TimeInterval, end: TimeInterval)?, loopMode: Bool, loopDelayTenths: Double) {
        guard let core, fileLoaded else { return }
        startEngineIfNeeded()
        var s = Self.frame(forSeconds: start)
        var loopFrames: (Int, Int)? = nil
        if let l = loopRange {
            let ls = Self.frame(forSeconds: l.start), le = Self.frame(forSeconds: l.end)
            if le > ls { loopFrames = (ls, le) }
        }
        if s >= (data?.frameCount ?? 1) { s = 0 }
        core.setPlaying(true, from: s, loop: loopFrames, loopMode: loopMode)
        core.update { c in c.loopDelayFrames = Int(loopDelayTenths / 10.0 * Self.canonicalRate) }
        isPlaying = true
        isPaused = false
        startDisplayTimer()
    }

    func pause() {
        core?.update { c in c.isPlaying = false }
        isPlaying = false
        isPaused = true
    }

    func stopPlayback() {
        core?.update { c in c.isPlaying = false }
        isPlaying = false
        isPaused = false
        playingPoint = 0
    }

    func resume() {
        guard let core, core.readout.readFrame < (data?.frameCount ?? 0) else { return }
        startEngineIfNeeded()
        core.update { c in c.isPlaying = true }
        isPlaying = true
        isPaused = false
        startDisplayTimer()
    }

    func seek(to t: TimeInterval) {
        core?.seek(to: Self.frame(forSeconds: t))
    }

    func setLoopRange(_ range: (start: TimeInterval, end: TimeInterval)?) {
        guard let r = range else { core?.setLoopRange(nil); return }
        let s = Self.frame(forSeconds: r.start), e = Self.frame(forSeconds: r.end)
        core?.setLoopRange(e > s ? (s, e) : nil)
    }

    // MARK: Position display

    private func startDisplayTimer() {
        guard displayTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        displayTimer = t
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tick() {
        let cfg = core?.readout ?? RenderConfig()
        playingPoint = Self.seconds(forFrame: cfg.readFrame)
        // Peak/compressor indication, sampled from the real-time tap's lock-guarded store.
        let peak = takePeak()
        let over = 20.0 * log10(max(Double(peak), 1e-6))
        redLevel = max(0, over) // dB above 0dBFS
        // End of file without loop?
        if isPlaying, !cfg.loopMode || !cfg.hasLoopRange, cfg.readFrame >= (data?.frameCount ?? 0) - 1 {
            stopPlayback()
            onPlayEnded?()
        }
    }

    // MARK: Access for spectrum (background-safe: only reads lock-guarded config + immutable data)

    var audioData: AudioData? { data }

    /// Mono-mixed window (honoring the current mix), for spectrum analysis.
    /// `nonisolated` — safe off-main: RenderCore state is NSLock-guarded, AudioData is immutable.
    nonisolated func monoWindow(at seconds: TimeInterval, length: Int) -> [Float] {
        let data = self.data
        guard let data else { return [] }
        let cfg = core?.readout ?? RenderConfig()
        let start = Self.frame(forSeconds: seconds)
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let f = start + i
            guard f >= 0, f < data.frameCount else { break }
            let l = data.channels[0][f]
            let r = data.channels.count > 1 ? data.channels[1][f] : l
            switch cfg.mixMode {
            case .stereo, .mono: out[i] = (l + r) * 0.5
            case .left: out[i] = l
            case .right: out[i] = r
            case .karaoke: out[i] = (l - r) * Float(0.5 * (1.0 + cfg.mixBalance))
            }
        }
        return out
    }

    /// Peak data for waveform drawing: (min, max) pairs over a range.
    /// Main-thread only (canvas drawing); scans in-memory audio — fast for visible ranges.
    func peaks(from startSec: Double, to endSec: Double, count: Int) -> [(min: Float, max: Float)] {
        guard let data, count > 0 else { return [] }
        let total = data.frameCount
        let s = max(0, Self.frame(forSeconds: startSec))
        let e = min(total, max(s + 1, Self.frame(forSeconds: endSec)))
        let span = max(1, e - s)
        let bucket = Double(span) / Double(count)
        let asMono = displayAsMono
        var result = [(Float, Float)](repeating: (0, 0), count: count)
        for b in 0..<count {
            let b0 = s + Int(Double(b) * bucket)
            let b1 = min(e, s + Int(Double(b + 1) * bucket) + 1)
            var mn: Float = 0, mx: Float = 0
            var f = max(b0, 0)
            while f < b1 {
                var l = data.channels[0][f]
                var r = l
                if data.channels.count > 1 { r = data.channels[1][f] }
                if asMono { l = (l + r) * 0.5; r = l }
                if l < mn { mn = l }
                if l > mx { mx = l }
                if r < mn { mn = r }
                if r > mx { mx = r }
                f += 1
            }
            result[b] = (mn, mx)
        }
        return result
    }

    var displayAsMono = false
}
