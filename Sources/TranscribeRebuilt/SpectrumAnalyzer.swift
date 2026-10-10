import Foundation
import Accelerate

// MARK: - Spectrum results

struct SpectrumResult {
    /// Magnitude per FFT bin (0..<binCount/2), normalized so the max peak is 1.0 unless fixed scale is used.
    var mags: [Float]
    var binHz: Double
    var sourceSeconds: Double   // where in the file this spectrum was taken
    var label: String          // "Selection", "Playing point", etc.
    var noteGuesses: [NoteGuess]
    var chordGuesses: [String]
}

struct NoteGuess {
    var midi: Int
    var confidence: Double     // 0...1, blob size
    var centsOff: Double       // offset from equal-tempered center
    var inTune: Bool
}

// MARK: - Chord templates

struct ChordType {
    let name: String
    let intervals: Set<Int>   // pitch-class intervals above the root
    let essential: Set<Int>   // tones that make the chord what it is
}

let chordTemplates: [ChordType] = [
    ChordType(name: "",            intervals: [0, 4, 7],              essential: [0, 4, 7]),
    ChordType(name: "m",           intervals: [0, 3, 7],              essential: [0, 3, 7]),
    ChordType(name: "7",           intervals: [0, 4, 7, 10],          essential: [0, 10]),
    ChordType(name: "m7",          intervals: [0, 3, 7, 10],          essential: [0, 3, 10]),
    ChordType(name: "maj7",        intervals: [0, 4, 7, 11],          essential: [0, 11]),
    ChordType(name: "6",           intervals: [0, 4, 7, 9],           essential: [0, 9]),
    ChordType(name: "m6",          intervals: [0, 3, 7, 9],           essential: [0, 3, 9]),
    ChordType(name: "9",           intervals: [0, 4, 7, 10, 2],       essential: [0, 10, 2]),
    ChordType(name: "m9",          intervals: [0, 3, 7, 10, 2],       essential: [0, 3, 10, 2]),
    ChordType(name: "maj9",        intervals: [0, 4, 7, 11, 2],       essential: [0, 11, 2]),
    ChordType(name: "add9",        intervals: [0, 4, 7, 2],           essential: [0, 2]),
    ChordType(name: "sus4",        intervals: [0, 5, 7],              essential: [0, 5]),
    ChordType(name: "sus2",        intervals: [0, 2, 7],              essential: [0, 2]),
    ChordType(name: "dim",         intervals: [0, 3, 6],              essential: [0, 3, 6]),
    ChordType(name: "dim7",        intervals: [0, 3, 6, 9],           essential: [0, 3, 6, 9]),
    ChordType(name: "aug",         intervals: [0, 4, 8],              essential: [0, 4, 8]),
    ChordType(name: "m7b5",        intervals: [0, 3, 6, 10],          essential: [0, 3, 6, 10]),
    ChordType(name: "7sus4",       intervals: [0, 5, 7, 10],          essential: [0, 5, 10]),
    ChordType(name: "7#5",         intervals: [0, 4, 8, 10],          essential: [0, 8, 10]),
    ChordType(name: "7b9",         intervals: [0, 4, 7, 10, 1],       essential: [0, 10, 1]),
    ChordType(name: "13",          intervals: [0, 4, 7, 10, 2, 9],    essential: [0, 10, 2]),
    ChordType(name: "m11",         intervals: [0, 3, 7, 10, 2, 5],   essential: [0, 3, 10]),
]

let noteLettersSharp = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
let noteLettersFlat  = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

// MARK: - Analyzer

enum SpectrumAnalyzer {

    /// Point spectrum window: 0.25s centered on the point (per the original).
    static let pointWindow: Double = 0.25
    /// Maximum selection spectrum: first 1.0s of the selection.
    static let maxSelectionWindow: Double = 1.0

    /// Computes the spectrum of a mono window.
    /// `eqGains` (dB, 31 bands) are applied to the magnitude response so the spectrum
    /// reflects what you hear through the EQ (as in the original).
    static func analyze(mono: [Float], sampleRate: Double, label: String,
                        atSeconds: Double, eqActive: Bool, eqGains: [Double]?,
                        pitchFactor: Double, noteGuessing: Bool, chordGuessing: Bool) -> SpectrumResult? {
        let n = mono.count
        guard n >= 16 else { return nil }

        // FFT size: next power of two ≥ n (up to 1s @ 44.1k = 65536)
        let fftN = vDSP_Length(1 << (Int(log2(Double(n))) + 1))
        let fftNInt = Int(fftN)
        // vDSP's setup and fft_zrip take log2(size), NOT the size itself.
        let log2n = vDSP_Length(log2(Double(fftNInt)))  // fftN is a power of two → exact

        // Hann window + real FFT
        var window = [Float](repeating: 0, count: fftNInt)
        vDSP_hann_window(&window, fftN, Int32(vDSP_HANN_DENORM))
        var padded = [Float](repeating: 0, count: fftNInt)
        mono.withUnsafeBufferPointer { src in
            padded.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src.baseAddress!, count: min(n, fftNInt))
            }
        }
        var windowed = [Float](repeating: 0, count: fftNInt)
        vDSP_vmul(padded, 1, window, 1, &windowed, 1, vDSP_Length(fftNInt))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: fftNInt / 2)
        var imag = [Float](repeating: 0, count: fftNInt / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftNInt / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, fftN / 2)
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        var mags = [Float](repeating: 0, count: fftNInt / 2)
        var squaredReal = [Float](repeating: 0, count: fftNInt / 2)
        var squaredImag = [Float](repeating: 0, count: fftNInt / 2)
        vDSP_vsq(real, 1, &squaredReal, 1, vDSP_Length(fftNInt / 2))
        vDSP_vsq(imag, 1, &squaredImag, 1, vDSP_Length(fftNInt / 2))
        vDSP_vadd(squaredReal, 1, squaredImag, 1, &mags, 1, vDSP_Length(fftNInt / 2))
        var scale = Float(2.0 / Float(fftNInt))
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(fftNInt / 2))
        var sqrtMags = [Float](repeating: 0, count: fftNInt / 2)
        vvsqrtf(&sqrtMags, &mags, [Int32(fftNInt / 2)])
        mags = sqrtMags

        // Drop DC bin; apply EQ response if active
        let binCount = mags.count
        if binCount > 1 { mags[0] = 0 }
        if eqActive, let gains = eqGains {
            let nyquist = sampleRate / 2
            for k in 1..<binCount {
                let f = Double(k) / Double(fftNInt) * sampleRate
                var totalDb = 0.0
                for (i, center) in EQBands.centers.enumerated() {
                    totalDb += peakingGain(gains[i], center, EQBands.bandwidth, f)
                }
                let g = Float(pow(10.0, totalDb / 20.0))
                mags[k] *= g
            }
            _ = nyquist
        }

        // Normalize so the tallest peak fills the display (original's default behavior)
        var maxMag: Float = 0
        vDSP_maxv(mags, 1, &maxMag, vDSP_Length(binCount))
        if maxMag > 1e-9 {
            let norm = 1.0 / maxMag
            mags = mags.map { $0 * norm }
        }

        var result = SpectrumResult(mags: mags, binHz: sampleRate / Double(fftNInt),
                                     sourceSeconds: atSeconds, label: label,
                                     noteGuesses: [], chordGuesses: [])
        guard noteGuessing || chordGuessing else { return result }

        // Peak picking with harmonic discounting (see the original's guess.htm):
        // a peak is discounted if it could be a harmonic of a stronger lower peak.
        struct Peak { var hz: Double; var mag: Double }
        var peaks: [Peak] = []
        for k in 2..<(binCount - 1) {
            let m = Double(mags[k])
            guard m > 0.002 else { continue }                              // absolute floor
            guard m >= Double(mags[k - 1]), m >= Double(mags[k + 1]) else { continue }
            // parabolic interpolation for sub-bin frequency
            let a = Double(mags[k - 1]), b = m, c = Double(mags[k + 1])
            let denom = a - 2 * b + c
            let delta = denom != 0 ? 0.5 * (a - c) / denom : 0
            let hz = (Double(k) + delta) * result.binHz * pitchFactor // heard pitch includes tuning factor
            peaks.append(Peak(hz: hz, mag: m))
        }
        guard !peaks.isEmpty else { return result }

        // Discount harmonics
        var notes: [(midi: Double, conf: Double)] = []
        let sortedByFreq = peaks.sorted { $0.hz < $1.hz }
        for p in sortedByFreq {
            var factor = p.mag
            for q in sortedByFreq where q.hz < p.hz * 0.99 && q.mag > p.mag * 0.05 {
                let ratio = p.hz / q.hz
                let nearest = (ratio).rounded()
                if nearest >= 2, nearest <= 10, abs(ratio / nearest - 1) < 0.035 {
                    // could be a harmonic of q: discount by the strength of q
                    factor *= max(0.15, 1.0 - q.mag * 0.85)
                }
            }
            guard factor > 0.02 else { continue }
            let midi = NoteMath.midi(forFreq: p.hz)
            notes.append((midi, min(1.0, factor)))
        }

        // Merge peaks within the same MIDI note
        var merged: [(midi: Double, conf: Double)] = []
        for n in notes.sorted(by: { $0.midi < $1.midi }) {
            if let last = merged.last, Int(last.midi.rounded()) == Int(n.midi.rounded()) {
                if n.conf > last.conf { merged[merged.count - 1] = n }
            } else {
                merged.append(n)
            }
        }

        result.noteGuesses = merged.map { n in
            let m = Int(n.midi.rounded())
            let cents = (n.midi - Double(m)) * 100.0
            let inTune = abs(cents) < 25
            return NoteGuess(midi: m, confidence: n.conf, centsOff: cents, inTune: inTune)
        }

        // Chord guessing from note guesses: bass weighted more; may discard some upper notes.
        if chordGuessing {
            result.chordGuesses = guessChords(from: merged)
        }
        return result
    }

    /// RBJ peaking filter magnitude response (dB) at frequency `f`, for use in the spectrum display.
    static func peakingGain(_ gainDb: Double, _ center: Double, _ bandwidthOct: Double, _ f: Double) -> Double {
        guard abs(gainDb) > 0.01, center > 0, f > 0 else { return 0 }
        let A = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * .pi * center / 44100.0
        // Q for a given bandwidth in octaves
        let q = 1.0 / (pow(2.0, bandwidthOct / 2.0) - pow(2.0, -bandwidthOct / 2.0))
        let alpha = sin(w0) / (2.0 * q)
        let cw = cos(w0)
        let b0 = 1.0 + alpha * A, b1 = -2.0 * cw, b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A, a1 = -2.0 * cw, a2 = 1.0 - alpha / A
        let w = 2.0 * .pi * f / 44100.0
        // |H(e^{jw})| = |b0 + b1 e^{-jw} + b2 e^{-2jw}| / |a0 + a1 e^{-jw} + a2 e^{-2jw}|
        func mag(_ z0: Double, _ z1: Double, _ z2: Double) -> Double {
            let re = z0 + z1 * cos(-w) + z2 * cos(-2 * w)
            let im = z1 * sin(-w) + z2 * sin(-2 * w)
            return sqrt(re * re + im * im)
        }
        let h = mag(b0, b1, b2) / max(mag(a0, a1, a2), 1e-9)
        return 20.0 * log10(max(h, 1e-9))
    }

    static func guessChords(from notes: [(midi: Double, conf: Double)]) -> [String] {
        guard notes.count >= 2 else { return [] }
        // Low notes matter more (per the original's documentation).
        func weight(_ midi: Double) -> Double {
            let low = 48.0
            if midi <= low { return 2.0 }
            if midi <= 60 { return 1.5 }
            if midi <= 72 { return 1.0 }
            return 0.6
        }
        // Build weighted pitch-class presence
        var presence = [Double](repeating: 0, count: 12)
        var bassPc = Int(notes[0].midi.rounded()) % 12
        for n in notes {
            let pc = (Int(n.midi.rounded()) % 12 + 12) % 12
            presence[pc] = max(presence[pc], n.conf * weight(n.midi))
        }
        _ = bassPc; bassPc = (bassPc + 12) % 12

        // Try each root that is actually present
        struct Candidate { var score: Double; var name: String }
        var candidates: [Candidate] = []
        for root in 0..<12 where presence[root] > 0.05 {
            for type in chordTemplates {
                var score = 0.0
                var missingEssential = 0
                for iv in type.intervals {
                    let pc = (root + iv) % 12
                    if presence[pc] > 0.05 { score += presence[pc] } else { score -= 0.25 }
                }
                for pc in 0..<12 where presence[pc] > 0.05 {
                    if !type.intervals.contains((pc - root + 12) % 12) {
                        score -= presence[pc] * 0.5
                    }
                }
                for e in type.essential {
                    if presence[(root + e) % 12] < 0.05 { missingEssential += 1 }
                }
                if missingEssential > 0 { score -= 1.5 * Double(missingEssential) }
                // Bass note in the chord ⇒ slash notation only when bass isn't the root and IS a chord tone
                let bassInChord = type.intervals.contains((bassPc - root + 12) % 12)
                let bassBonus = bassInChord ? 0.2 : -0.8
                if bassPc != root && !bassInChord { continue } // never invent "F/B"-style names
                score += bassBonus
                candidates.append(Candidate(score: score, name: chordName(root: root, type: type, bass: bassPc)))
            }
        }
        // Deduplicate and rank; return top 3
        var seen = Set<String>()
        var out: [String] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            if seen.insert(c.name).inserted { out.append(c.name) }
            if out.count == 3 { break }
        }
        return out
    }

    static func chordName(root: Int, type: ChordType, bass: Int) -> String {
        // Choose sharp/flat spelling sensibly by root
        let flatRoots: Set<Int> = [1, 3, 6, 8, 10] // Db Eb Gb Ab Bb
        let letter = flatRoots.contains(root) ? noteLettersFlat[root] : noteLettersSharp[root]
        var name = letter + type.name
        if bass != root && type.intervals.contains((bass - root + 12) % 12) {
            name += "/" + (flatRoots.contains(bass) ? noteLettersFlat[bass] : noteLettersSharp[bass])
        }
        return name
    }

    /// Enharmonic alternatives for a chord guess ("C#" → also "Db").
    static func enharmonicAlternatives(_ chord: String) -> [String] {
        var out = [chord]
        // swap the root letter spelling if it has an accidental
        for (i, l) in noteLettersSharp.enumerated() {
            if chord.hasPrefix(l), l.contains("#") {
                out.append(noteLettersFlat[i] + chord.dropFirst(l.count))
                break
            }
        }
        for (i, l) in noteLettersFlat.enumerated() {
            if chord.hasPrefix(l), l.contains("b") && l.count == 2 {
                out.append(noteLettersSharp[i] + chord.dropFirst(l.count))
                break
            }
        }
        return out
    }
}
