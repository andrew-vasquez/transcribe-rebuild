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

        instantiateDynamicsProcessor()
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

    private func configureDynamics(_ unit: AVAudioUnit) {
        // kDynamicsProcessorParam_Threshold = 2000; soft limiting just below full scale
        var raw: AudioUnit
        if #available(macOS 27.0, *) {
            raw = unit.withAudioUnit { $0 }
        } else {
            raw = unit.audioUnit
        }
        var threshold: Float32 = -3.0
        AudioUnitSetParameter(raw, 2000, kAudioUnitScope_Global, 0, threshold, 0)
        // kDynamicsProcessorParam_HeadRoom = 2001
        var headroom: Float32 = 5.0
        AudioUnitSetParameter(raw, 2001, kAudioUnitScope_Global, 0, headroom, 0)
        // kDynamicsProcessorParam_Ratio = 2002
        var ratio: Float32 = 20.0
        AudioUnitSetParameter(raw, 2002, kAudioUnitScope_Global, 0, ratio, 0)
        // kDynamicsProcessorParam_AttackTime = 2004
        var attack: Float32 = 0.002
        AudioUnitSetParameter(raw, 2004, kAudioUnitScope_Global, 0, attack, 0)
        // kDynamicsProcessorParam_ReleaseTime = 2005
        var release: Float32 = 0.1
        AudioUnitSetParameter(raw, 2005, kAudioUnitScope_Global, 0, release, 0)
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

        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: totalFrames) else {
            throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate buffer"])
        }
        try file.read(into: srcBuf, frameCount: totalFrames)

        // Convert to canonical Float32 stereo 44.1k, deinterleaved
        var channelArrays: [ContiguousArray<Float>] = []
        let chCount = Int(srcFormat.channelCount)
        guard let deinter = srcBuf.floatChannelData else { throw NSError(domain: "Audio", code: 2) }
        let frames = Int(srcBuf.frameLength)

        // Convert per source channel to 44.1k
        var converted: [ContiguousArray<Float>] = []
        for c in 0..<chCount {
            var raw = ContiguousArray<Float>(repeating: 0, count: frames)
            for i in 0..<frames { raw[i] = deinter[c][i] }
            converted.append(resample(raw, from: srcFormat.sampleRate, to: Self.canonicalRate))
        }
        // Reduce to stereo
        if converted.count == 1 {
            channelArrays = [converted[0], converted[0]]
        } else if converted.count >= 2 {
            channelArrays = [converted[0], converted[1]]
        }

        let data = AudioData(channels: channelArrays, click: Self.makeClick())
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
        if let comp = compressorNode {
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
