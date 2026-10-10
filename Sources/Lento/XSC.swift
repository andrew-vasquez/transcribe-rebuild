import Foundation

/// Reads and writes Transcribe! `.xsc` transcription files.
///
/// The format (from the application's own help, `xsc_files.htm`):
/// - Comma-delimited UTF-8 text, sections delimited by `SectionStart,<name>` / `SectionEnd,<name>`.
/// - Escaping within fields: `,` → `\C`, `\` → `\\`, newline → `\n`.
/// - `[Main]` holds `SoundFileName` (short / long) and `SoundFileInfo`.
/// - `[View0]`… hold per-view FX.
/// - Markers rows: `S|M|B, sample(-1 = use timestamp), autoLabel(0/1), label, subdivision, h:mm:ss.ffffff`.
/// - Text block rows: `T, pos, vpos, width(px), color, timecode, text`.
///
/// The rebuild writes this same grammar so files interoperate with the original app
/// for markers and text blocks.
enum XSC {

    // MARK: Escaping

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case ",": out += "\\C"
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.append(ch)
            }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\" {
                guard let n = it.next() else { out.append(c); break }
                switch n {
                case "C": out.append(",")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                default: out.append("\\"); out.append(n)
                }
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: Write

    @MainActor
    static func write(doc: TranscriptionDocument, to url: URL) throws {
        var lines: [String] = []
        lines.append("SectionStart,Main")
        let soundPath = doc.fileInfo?.url.path ?? ""
        lines.append("SoundFileName,\(escape((soundPath as NSString).lastPathComponent)),\(escape(soundPath))")
        if let fi = doc.fileInfo {
            lines.append("SoundFileInfo,\(escape(fi.formatName)),,\(fi.channels),\(fi.frames * fi.channels * 2),\(Int(fi.sampleRate)),\(fi.frames),\(String(format: "%.3f", fi.duration))")
        }
        lines.append("SectionEnd,Main")

        lines.append("SectionStart,View0")
        let fx = doc.fx
        lines.append("FxSpeed,\(String(format: "%.5f", fx.speed)),\(fx.analogLock ? 1 : 0)")
        lines.append("FxTuning,\(fx.octaves),\(fx.semitones),\(String(format: "%.2f", fx.cents))")
        lines.append("FxTransposition,\(fx.transpositionSemitones),\(String(format: "%.2f", fx.transpositionCents))")
        lines.append("FxEQ,\(fx.eqActive ? 1 : 0)")
        lines.append("FxEqGains" + fx.eqGains.enumerated().map { ",\(String(format: "%.2f", $0.element))" }.joined())
        lines.append("FxMono,\(fx.mixActive ? 1 : 0),\(fx.mixMode.rawValue),\(String(format: "%.4f", fx.mixBalance))")
        lines.append("FxVolume,\(String(format: "%.2f", fx.volume))")
        lines.append("LoopMode,\(doc.loopMode ? 1 : 0)")
        lines.append("CurrentPoint,\(String(format: "%.6f", doc.currentPoint))")
        lines.append("SectionEnd,View0")

        let ms = doc.markersSorted()
        lines.append("SectionStart,Markers")
        lines.append("Howmany,\(ms.count)")
        for m in ms {
            lines.append("\(m.kind.rawValue),-1,\(m.autoLabel ? 1 : 0),\(escape(m.label)),\(m.subdivision),\(TimeFormat.xsc(m.position))")
        }
        lines.append("SectionEnd,Markers")

        lines.append("SectionStart,TextBlocks")
        lines.append("Howmany,\(doc.textBlocks.count)")
        for b in doc.textBlocks.sorted(by: { $0.position < $1.position }) {
            lines.append("T,-1,\(b.verticalRow),\(Int(b.widthPx)),\(b.colorIndex),\(TimeFormat.xsc(b.position)),\(escape(b.text))")
        }
        lines.append("SectionEnd,TextBlocks")

        lines.append("SectionStart,Loops")
        lines.append("Howmany,\(doc.loops.count)")
        for l in doc.loops {
            var row = "L,-1,\(l.hasPosition ? 1 : 0),\(TimeFormat.xsc(l.position)),\(l.hasSelection ? 1 : 0),\(TimeFormat.xsc(l.selectionStart)),\(TimeFormat.xsc(l.selectionEnd)),\(escape(l.name)),\(l.colorIndex),\(l.fxApplied ? 1 : 0)"
            if l.fxApplied {
                row += ",\(String(format: "%.5f", l.fx.speed)),\(l.fx.octaves),\(l.fx.semitones),\(String(format: "%.2f", l.fx.cents)),\(l.fx.volume)"
            }
            lines.append(row)
        }
        lines.append("SectionEnd,Loops")

        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Read

    static func parse(at url: URL) throws -> (soundPath: String?, markers: [Marker], textBlocks: [TextBlock], loops: [StoredLoop], fx: FxState, currentPoint: TimeInterval?) {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var soundPath: String?
        var markers: [Marker] = []
        var textBlocks: [TextBlock] = []
        var loops: [StoredLoop] = []
        var fx = FxState()
        var currentPoint: TimeInterval?
        var section = ""
        var lastAutoSubdivision = 0

        for line in raw.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let f = splitFields(line)

            if f[0] == "SectionStart", f.count > 1 {
                section = f[1]
                continue
            }
            if f[0] == "SectionEnd" { section = ""; continue }

            switch section {
            case "Main":
                if f[0] == "SoundFileName" {
                    // Prefer the "long" (full path) form; fall back to the short name.
                    soundPath = f.count > 2 ? unescape(f[2]) : (f.count > 1 ? unescape(f[1]) : nil)
                }
            case "View0", "View1", "Play", "Main":
                switch f[0] {
                case "FxSpeed" where f.count > 2:
                    fx.speed = Double(f[1]) ?? 100
                    fx.analogLock = (f[2] == "1")
                case "FxTuning" where f.count > 3:
                    fx.octaves = Int(f[1]) ?? 0
                    fx.semitones = Int(f[2]) ?? 0
                    fx.cents = Double(f[3]) ?? 0
                case "FxTransposition" where f.count > 2:
                    fx.transpositionSemitones = Int(f[1]) ?? 0
                    fx.transpositionCents = Double(f[2]) ?? 0
                case "FxEQ" where f.count > 1:
                    fx.eqActive = (f[1] == "1")
                case "FxEqGains":
                    let gains = f.dropFirst().compactMap { Double($0) }
                    if gains.count == EQBands.count { fx.eqGains = gains }
                case "FxMono" where f.count > 3:
                    fx.mixActive = (f[1] == "1")
                    fx.mixMode = MixMode(rawValue: f[2]) ?? .stereo
                    fx.mixBalance = Double(f[3]) ?? 0
                case "FxVolume" where f.count > 1:
                    fx.volume = Double(f[1]) ?? 100
                case "CurrentPoint" where f.count > 1:
                    currentPoint = Double(f[1])
                default:
                    break
                }
            case "Markers":
                if f[0] == "S" || f[0] == "M" || f[0] == "B", f.count >= 6 {
                    let kind = MarkerKind(rawValue: f[0]) ?? .beat
                    var position: TimeInterval?
                    if f[1] != "-1" { position = Double(f[1]) ?? 0 } // sample number; needs rate — handled by caller if needed
                    if position == nil, f.count > 5 {
                        position = parseXscTime(f[5])
                    }
                    guard let pos = position else { continue }
                    var subdiv = Int(f[4]) ?? 0
                    if subdiv == 0 { subdiv = lastAutoSubdivision } else { lastAutoSubdivision = subdiv }
                    markers.append(Marker(kind: kind, position: pos, autoLabel: f[2] == "1", label: unescape(f[3]), subdivision: subdiv))
                }
            case "TextBlocks":
                if f[0] == "T", f.count >= 7 {
                    var position: TimeInterval?
                    if f[1] != "-1" { position = Double(f[1]) ?? 0 }
                    if position == nil { position = parseXscTime(f[5]) }
                    let text = f.count > 6 ? unescape(f[6...].joined(separator: ",")) : ""
                    textBlocks.append(TextBlock(position: position ?? 0, verticalRow: Int(f[2]) ?? 0, widthPx: Double(f[3]) ?? 180, colorIndex: Int(f[4]) ?? 0, text: text))
                }
            case "Loops":
                if f[0] == "L", f.count >= 7 {
                    var l = StoredLoop()
                    l.hasPosition = f[2] == "1"
                    l.position = parseXscTime(f[3]) ?? 0
                    l.hasSelection = f[4] == "1"
                    l.selectionStart = parseXscTime(f[5]) ?? 0
                    l.selectionEnd = parseXscTime(f[6]) ?? 0
                    if f.count > 7 { l.name = unescape(f[7]) }
                    if f.count > 8 { l.colorIndex = Int(f[8]) ?? 0 }
                    if f.count > 9 { l.fxApplied = f[9] == "1" }
                    if l.fxApplied, f.count > 13 {
                        l.fx.speed = Double(f[10]) ?? 100
                        l.fx.octaves = Int(f[11]) ?? 0
                        l.fx.semitones = Int(f[12]) ?? 0
                        l.fx.cents = Double(f[13]) ?? 0
                        if f.count > 14 { l.fx.volume = Double(f[14]) ?? 100 }
                    }
                    loops.append(l)
                }
            default:
                break
            }
        }
        return (soundPath, markers, textBlocks, loops, fx, currentPoint)
    }

    /// `h:mm:ss.ffffff` → seconds
    static func parseXscTime(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Splits a line into fields, honoring the `\C` escaped comma (an unescaped comma).
    static func splitFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var it = line.makeIterator()
        while let c = it.next() {
            if c == "\\" {
                if let n = it.next() {
                    if n == "C" { current += "\\C" }       // keep escaped comma as token, unescaped later
                    else if n == "\\" { current += "\\\\" }
                    else if n == "n" { current += "\\n" }
                    else { current.append(c); current.append(n) }
                    continue
                }
                current.append(c)
            } else if c == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        fields.append(current)
        return fields
    }
}
