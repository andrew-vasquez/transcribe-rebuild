import Foundation
import Observation

// MARK: - Marker

enum MarkerKind: String, Codable, CaseIterable {
    case section = "S"
    case measure = "M"
    case beat = "B"
}

struct Marker: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kind: MarkerKind
    /// Position in seconds within the sound file.
    var position: TimeInterval
    /// Whether the label is auto-generated (as opposed to typed by the user).
    var autoLabel: Bool
    var label: String
    /// 0 = same as previous, 1 = none, 2+ = divide into N subdivisions.
    var subdivision: Int

    static func == (a: Marker, b: Marker) -> Bool { a.id == b.id }
}

// MARK: - Text block

struct TextBlock: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var position: TimeInterval
    var verticalRow: Int
    var widthPx: Double
    var colorIndex: Int
    var text: String

    static func == (a: TextBlock, b: TextBlock) -> Bool { a.id == b.id }
}

// MARK: - Stored loop (position/selection + optional FX snapshot)

struct StoredLoop: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var colorIndex: Int = 0
    var hasPosition: Bool = false
    var position: TimeInterval = 0
    var hasSelection: Bool = false
    var selectionStart: TimeInterval = 0
    var selectionEnd: TimeInterval = 0
    var fxApplied: Bool = false
    var fx: FxState = FxState()

    static func == (a: StoredLoop, b: StoredLoop) -> Bool { a.id == b.id }
}

// MARK: - FX state (per view; one view in v1)

struct FxState: Codable, Equatable {
    // Speed page
    var speed: Double = 100.0            // percent, 5...200
    var analogLock: Bool = false
    // Tuning page
    var octaves: Int = 0                 // -3...3
    var semitones: Int = 0               // -11...11
    var cents: Double = 0                // -50...50
    // Transposition page
    var transpositionSemitones: Int = 0
    var transpositionCents: Double = 0
    // EQ page
    var eqActive: Bool = false
    var eqGains: [Double] = Array(repeating: 0.0, count: 31)
    // Mono / Karaoke page
    var mixActive: Bool = false
    var mixMode: MixMode = .stereo
    var mixBalance: Double = 0          // -1 (all L) ... +1 (all R), used by left/right/karaoke balance
    // Misc page
    var volume: Double = 100.0          // percent

    var tuningCentsTotal: Double {
        Double(octaves) * 1200.0 + Double(semitones) * 100.0 + cents
    }
}

enum MixMode: String, Codable, CaseIterable {
    case stereo
    case mono
    case left
    case right
    case karaoke
}

// MARK: - Sound file info

struct SoundFileInfo: Codable, Equatable {
    var url: URL
    var sampleRate: Double
    var channels: Int
    var frames: Int
    var duration: TimeInterval { Double(frames) / sampleRate }
    var formatName: String
}

// MARK: - Transcription document (one per window)

@MainActor
@Observable
final class TranscriptionDocument {
    var fileInfo: SoundFileInfo?
    /// Path of the saved .xsc, if saved.
    var xscURL: URL?
    var modified = false

    // View state
    var fx = FxState()
    var markers: [Marker] = []
    var textBlocks: [TextBlock] = []
    var loops: [StoredLoop] = []
    var loopsExpanded: Bool = true

    /// The current point — where playback begins (the little red triangle).
    var currentPoint: TimeInterval = 0
    /// Selection, if any. `hasSelection` false → current point only.
    var hasSelection = false
    var selectionStart: TimeInterval = 0
    var selectionEnd: TimeInterval = 0

    var selection: ClosedRange<TimeInterval>? {
        hasSelection ? selectionStart...selectionEnd : nil
    }

    // Playback state (mutual exclusion enforced by Transport)
    var isPlaying = false
    var isPaused = false
    var playingPoint: TimeInterval = 0
    /// Loop mode on/off (menu checkmark).
    var loopMode = true
    var loopDelayTenths: Double = 0
    /// Metronome clicks at markers (Play menu) and their volume (Misc page).
    var clicksOn = false
    var clickVolume: Double = 0.6
    /// Transient position for the springy pop when a marker is placed (cleared by the view).
    var lastMarkerAddedAt: TimeInterval?

    // View options
    var showSpectrum = true
    var showNoteGuesses = true
    var showChordGuesses = true
    var showTimeLine = true
    var showNavigationBar = true
    var showTextZone = false
    var showDBLines = false
    var displayAsMono = false

    // Zoom/scroll (seconds per window width)
    var secondsVisible: Double = 30
    var scrollCenter: TimeInterval = 15
    var verticalZoom: Double = 1.0

    // EQ presets (global, saved to defaults)
    var eqPresets: [(name: String, gains: [Double])] = []

    let undo = UndoManager()

    // MARK: Derived marker helpers

    func markersSorted() -> [Marker] { markers.sorted { $0.position < $1.position } }

    /// Auto labels: sections lettered A, B, C…; measures numbered within sections ("A2"); beats unlabelled.
    func recomputeAutoLabels() {
        var sectionIdx = 0
        var measureInSection = 0
        var updates: [(id: UUID, label: String)] = []
        for m in markersSorted() {
            switch m.kind {
            case .section:
                sectionIdx += 1
                measureInSection = 0
                if m.autoLabel { updates.append((m.id, letter(for: sectionIdx))) }
            case .measure:
                measureInSection += 1
                if m.autoLabel {
                    let label = measureInSection == 1
                        ? letter(for: sectionIdx)
                        : "\(letter(for: sectionIdx))\(measureInSection)"
                    updates.append((m.id, label))
                }
            case .beat:
                if m.autoLabel { updates.append((m.id, "")) }
            }
        }
        for u in updates {
            if let i = markers.firstIndex(where: { $0.id == u.id }) { markers[i].label = u.label }
        }
    }

    private func letter(for n: Int) -> String {
        var s = "", n = n
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(65 + r)!) + s
            n = (n - 1) / 26
        }
        return s
    }

    // MARK: Mutations (undoable via snapshot)

    /// Snapshots markers for a single undo step before a mutation.
    private func withMarkerUndo(_ label: String, _ mutate: () -> Void) {
        let snapshot = markers
        mutate()
        recomputeAutoLabels()
        modified = true
        undo.registerUndo(withTarget: self) { doc in
            let redo = doc.markers
            doc.markers = snapshot
            doc.recomputeAutoLabels()
            doc.undo.registerUndo(withTarget: doc) { d2 in
                d2.markers = redo
                d2.recomputeAutoLabels()
            }
        }
    }

    func addMarker(_ kind: MarkerKind, at position: TimeInterval, silent: Bool = false) {
        withMarkerUndo("Add Marker") {
            markers.append(Marker(kind: kind, position: position, autoLabel: true, label: "", subdivision: 0))
        }
        lastMarkerAddedAt = position
        _ = silent
    }

    func deleteMarkers(in range: ClosedRange<TimeInterval>) {
        withMarkerUndo("Delete Markers") {
            markers.removeAll { range.contains($0.position) }
        }
    }

    func updateMarker(_ marker: Marker) {
        withMarkerUndo("Edit Marker") {
            if let i = markers.firstIndex(where: { $0.id == marker.id }) {
                markers[i] = marker
            } else {
                markers.append(marker)  // sheet created a new marker
            }
        }
    }

    func deleteMarker(_ marker: Marker) {
        withMarkerUndo("Delete Marker") {
            markers.removeAll { $0.id == marker.id }
        }
    }

    func moveMarker(_ marker: Marker, to position: TimeInterval) {
        if let i = markers.firstIndex(where: { $0.id == marker.id }) {
            let id = markers[i].id
            withMarkerUndo("Move Marker") {
                if let j = markers.firstIndex(where: { $0.id == id }) { markers[j].position = position }
            }
        }
    }

    func addTextBlock(at position: TimeInterval) {
        textBlocks.append(TextBlock(position: position, verticalRow: textBlocks.count, widthPx: 180, colorIndex: 0, text: "…"))
        modified = true
    }

    func deleteTextBlock(_ block: TextBlock) {
        textBlocks.removeAll { $0.id == block.id }
        modified = true
    }

    // MARK: Selection helpers

    func setCurrentPoint(_ t: TimeInterval, extendSelection: Bool = false) {
        let dur = fileInfo?.duration ?? 0
        let clamped = min(max(t, 0), dur)
        if extendSelection, hasSelection {
            if clamped < selectionStart { selectionStart = clamped } else { selectionEnd = clamped }
        } else {
            hasSelection = false
            currentPoint = clamped
        }
    }

    func setSelection(from a: TimeInterval, to b: TimeInterval) {
        let lo = min(a, b), hi = max(a, b)
        let dur = fileInfo?.duration ?? 0
        selectionStart = min(max(lo, 0), dur)
        selectionEnd = min(max(hi, 0), dur)
        hasSelection = selectionEnd - selectionStart > 1.0 / 1000.0
        currentPoint = selectionStart
    }

    func collapseSelectionToLeft() {
        if hasSelection { hasSelection = false; currentPoint = selectionStart }
    }

    // MARK: Tempo (Compute Tempo, per Markers menu)

    /// Counts markers in the selection, divides time span → BPM. Returns nil and a reason if unusable.
    func computeTempo() -> (bpmOriginal: Double, bpmAltered: Double)? {
        guard let sel = selection else { return nil }
        let ms = markersSorted().filter { sel.contains($0.position) }
        guard ms.count >= 2 else { return nil }
        let span = ms.last!.position - ms.first!.position
        guard span > 0 else { return nil }
        let beats = Double(ms.count - 1)
        let bpm = beats / span * 60.0
        let altered = bpm * fx.speed / 100.0
        return (bpm, altered)
    }

    // MARK: Equally Space Selected Markers

    func equallySpaceMarkers() {
        guard let sel = selection else { return }
        var ms = markers.filter { sel.contains($0.position) && $0.kind != .beat }.sorted { $0.position < $1.position }
        guard ms.count >= 2 else { return }
        let first = ms.first!.position, last = ms.last!.position
        guard last > first else { return }

        withMarkerUndo("Equally Space Markers") {
            let step = (last - first) / Double(ms.count - 1)
            for i in ms.indices { ms[i].position = first + Double(i) * step }
            // write the spaced positions back by id
            for m in ms {
                if let i = markers.firstIndex(where: { $0.id == m.id }) { markers[i].position = m.position }
            }
            // Redistribute beat markers evenly inside each measure (between two non-beat markers).
            let all = markers.sorted { $0.position < $1.position }
            for i in 0..<(all.count - 1) {
                let anchor = all[i], next = all[i + 1]
                guard next.position > anchor.position else { continue }
                // Count consecutive beats that follow `anchor` before `next`.
                var beatCount = 0
                var j = i + 1
                while j < all.count && all[j].kind == .beat && all[j].position < next.position { beatCount += 1; j += 1 }
                guard beatCount > 0 else { continue }
                let bs = (next.position - anchor.position) / Double(beatCount + 1)
                for k in 1...beatCount {
                    let target = anchor.position + Double(k) * bs
                    if let idx = markers.firstIndex(where: { $0.id == all[i + k].id }) { markers[idx].position = target }
                }
            }
        }
    }

    // MARK: Loops

    func ensureLoopSlots() {
        while loops.count < 20 {
            loops.append(StoredLoop())
        }
    }

    func storeLoop(_ index: Int) {
        ensureLoopSlots()
        loops[index].hasPosition = true
        loops[index].position = currentPoint
        loops[index].hasSelection = hasSelection
        loops[index].selectionStart = selectionStart
        loops[index].selectionEnd = selectionEnd
        modified = true
    }

    func recallLoop(_ index: Int) {
        guard loops.indices.contains(index), loops[index].hasPosition else { return }
        currentPoint = loops[index].position
        if loops[index].hasSelection {
            setSelection(from: loops[index].selectionStart, to: loops[index].selectionEnd)
        } else {
            hasSelection = false
        }
        if loops[index].fxApplied { fx = loops[index].fx }
    }

    // MARK: FX presets

    func loadEqPresetsFromDefaults() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "eqPresets"), let arr = try? JSONDecoder().decode([EqPreset].self, from: data) {
            eqPresets = arr.map { ($0.name, $0.gains) }
        } else {
            eqPresets = EQBands.defaultPresets()
        }
    }

    struct EqPreset: Codable { let name: String; let gains: [Double] }

    func saveEqPresets() {
        let arr = eqPresets.map { EqPreset(name: $0.name, gains: $0.gains) }
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: "eqPresets")
        }
    }
}
