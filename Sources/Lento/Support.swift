import Foundation

// MARK: - Time formatting (mirrors Transcribe!'s boxes: minutes & seconds, h:mm:ss.ffffff for xsc)

enum TimeFormat {
    /// "3.5" means seconds; bare integer means minutes; "1m", "2s", "1:3.6", "1m3.6" all parse.
    static func parse(_ s: String) -> TimeInterval? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false)
            var total = 0.0
            for p in parts { total = total * 60.0 + (Double(p) ?? 0) }
            return total
        }
        if let m = t.range(of: "m") {
            let mins = Double(t[t.startIndex..<m.lowerBound]) ?? 0
            let rest = t[m.upperBound...]
            return mins * 60.0 + (Double(rest) ?? 0)
        }
        if let sIdx = t.range(of: "s") {
            return Double(t[t.startIndex..<sIdx.lowerBound]) ?? 0
        }
        guard let v = Double(t) else { return nil }
        // bare number: minutes unless it has a decimal point
        return t.contains(".") ? v : v * 60.0
    }

    /// mm:ss
    static func short(_ secs: TimeInterval) -> String {
        let t = max(0, secs)
        let m = Int(t / 60)
        let s = t - TimeInterval(m) * 60
        return String(format: "%d:%04.1f", m, s)
    }

    /// h:mm:ss.ffffff — used in .xsc files (v9+ format)
    static func xsc(_ secs: TimeInterval) -> String {
        let t = max(0, secs)
        let h = Int(t / 3600)
        let m = Int(t / 60) % 60
        let s = t - TimeInterval(h) * 3600 - TimeInterval(m) * 60
        return String(format: "%d:%02d:%09.6f", h, m, s)
    }
}

// MARK: - Note math

enum NoteMath {
    /// MIDI note number (0 = C0) for a frequency. A4 = 69 @ 440Hz.
    static func midi(forFreq f: Double, a4: Double = 440.0) -> Double {
        guard f > 0 else { return 0 }
        return 69.0 + 12.0 * log2(f / a4)
    }

    static func freq(forMidi m: Double, a4: Double = 440.0) -> Double {
        a4 * pow(2.0, (m - 69.0) / 12.0)
    }

    /// Note name like "C4", "F#3". Middle C = C4 (configurable in the original; we default C4).
    static func name(forMidi m: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[(m % 12 + 12) % 12] + String(m / 12)
    }

    static func pitchClass(_ midi: Int) -> Int { ((midi % 12) + 12) % 12 }
}

// MARK: - 31-band graphic EQ: ISO 1/3-octave centers (20Hz..20kHz), as in the original

enum EQBands {
    static let centers: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
        800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000,
        12500, 16000, 20000
    ]
    static let count = centers.count
    static let bandwidth = 1.0 / 3.0 // octaves (parametric EQ bandwidth)
    static let maxGain: Double = 20.0
    static let minGain: Double = -80.0

    /// Default instrument presets, mirroring the original's shipped set.
    static func defaultPresets() -> [(name: String, gains: [Double])] {
        func boost(_ low: Double, _ mid: Double, _ high: Double) -> [Double] {
            (0..<count).map { i in
                let f = centers[i]
                if f < 200 { return low }
                if f < 2000 { return mid }
                return high
            }
        }
        return [
            ("Bass", boost(9, 0, 2)),
            ("Tenor (tenor sax, trombone, guitar)", boost(-4, 7, 3)),
            ("Alto", boost(-2, 6, 2)),
            ("Soprano (violin, mandolin)", boost(-4, 4, 6)),
            ("Vocal", boost(-3, 2, 3)),
            ("Piano", boost(3, 0, 1)),
            ("Drums", boost(6, 0, 4)),
        ]
    }
}
