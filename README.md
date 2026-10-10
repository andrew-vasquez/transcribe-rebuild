# Transcribe Rebuilt

A native macOS (arm64, SwiftUI + AppKit + AVAudioEngine) rebuild of **Seventh String's Transcribe! 9.70.1** — built entirely from shipped-artifact reverse-engineering evidence. The original is a C++ wxWidgets application; this rebuild uses the same OS surfaces it links (CoreAudio, AVFoundation, Accelerate) through modern Swift.

**See [`docs/REVERSE-ENGINEERING-EVIDENCE.md`](docs/REVERSE-ENGINEERING-EVIDENCE.md) for the complete REA evidence report** — bundle inventory, Mach-O/linkage evidence, the application's own 71-page help book (extracted from `xschelp.htb`), runtime menu dumps, and the feature spec this rebuild implements against.

## Build & run

```sh
swift build -c release
./scripts/make-app.sh          # bundles build/Transcribe Rebuilt.app (+ icon)
open "build/Transcribe Rebuilt.app"
```

Or in dev: `swift run` (note: a few platform behaviors — window restoration polish, Launch Services registration — are better via the bundle).

Requires Xcode 27 / macOS 26 SDK+ (uses `glassEffect`, `UtilityWindow`, `restorationBehavior`).

## What's implemented (v1 core, per the evidence spec)

- **Files**: open audio (WAV/AIFF/MP3/FLAC/M4A/AAC…), drag-drop, command-line/file-open launch (as the original supports), recent files; **save/load native `.xsc` transcription files** (comma-delimited UTF-8, markers + text blocks format-compatible with the original app)
- **Waveform view**: stereo-split profile, zoom (horizontal/vertical, ⌘-wheel), scroll bar with play position, navigation bar (sections/measures, click-to-jump), time line, current-point red triangles, selection with shift/drag semantics, dB lines
- **Transport**: play/pause/stop/resume, gapless looping (selection or range), loop A-B, loop delay, cue/review, scroll-follow, all live-changeable during playback
- **Speed**: 5–200%, pitch-preserved (Apple TimePitch), **analog lock** (Varispeed — tape-style speed⇄pitch interlock), presets 100/70/50/35% in the header bar, `⌘1–4`/`⌘7–0` accelerators
- **Tuning**: octaves/semitones/cents (±3 octaves via TimePitch+Varispeed split), A=440 Hz reference display, reference-note player
- **31-band graphic EQ**: ISO ⅓-octave centers (20 Hz–20 kHz), ±20 dB to −80 dB, elastic neighbor sliders (shift = faster spread), global named presets (default instrument set), Active/Bypass per page
- **Mono/Karaoke mixer**: stereo/mono/left/right/karaoke (out-of-phase cancellation) with balance
- **Compressor**: Apple DynamicsProcessor AU (threshold −3 dB, 20:1) with a red overload bar in the lower bar
- **Markers**: Section/Measure/Beat, auto-labelling (A, A2…), S/M/B placement at the playing point, drag-to-move, edit sheet (type/label/subdivision), delete-in-selection, Equally Space, **Compute Tempo** (original + altered BPM), metronome clicks at markers (synthesized wooden tick)
- **Spectrum**: 0.25 s point spectrum / 1 s selection spectrum, vDSP FFT, EQ-response applied, auto vertical scaling, dB lines, log-frequency piano keyboard with note-centre lines, C-octave labelling, click to play reference tones, harmonic-grid on click
- **Note & chord guessing**: peak-picking with harmonic discounting, green/red (in/out of tune) confidence blobs, chord template matching (~20 chord types, slash chords, enharmonic alternates) — all per the original's documented algorithm
- **Loops**: 20 stored slots (position/selection + FX snapshot), recall/store, names, colors, location indicators
- **Keyboard**: the original's default shortcut map (space, `.`/`,`, C/R, O/P scrub, S/M/B, T, E/D, J/K/L, 1–4, U/I, Q/W, arrows/[/] selection moves, Shift/Ctrl/Option marker jumps) — via a responder-chain key catcher
- **Menus**: File (Open/Save/Import/Export WAV/Export markers), Play, Markers, View, Text — merged into the system menus, matching the original's menu dump
- **Export**: WAV (16-bit 44.1 kHz) through the current FX chain offline-render (whole/selection, N repetitions), markers & text blocks to text
- **Windows**: main transcription window + floating glass FX panel (`UtilityWindow`) with the original's six pages (Mono/Karaoke, EQ, Tuning, Transposition, Speed, Misc) + native Settings scene

## Known deviations from the original (documented, not bugs)

- Video, MIDI/pedal input, scripting (`.xscscpt`), recording, stems, split views, piano-roll view, global shortcuts, fret display: **roadmap** (see the evidence report §6 for the original's spec of each)
- Cue/Review are seek-jumps (±5 s) rather than accelerating varispeed fast-forward
- OGG Vorbis decode needs a Swift package (Apple decoders cover the rest)
- The HQ slowdown uses Apple's TimePitch rather than the original's private algorithm (unknown — see evidence §5)
- MP3 export is not included (WAV export is)

## Platform notes (macOS 27.2 beta)

Two beta bugs were diagnosed and engineered around, with the workaround documented in code:
1. **NSEvent local monitors over-release events** → shortcuts use a responder-chain `keyDown`/`keyUp` catcher instead (better design anyway: focused text fields consume keys first, like the original).
2. **NSToolbar menu-form representation corrupts the heap** (font/CoreText malloc freelist crashes) → the header toolbar is drawn in content (`.bar` material + glass grouping), which also matches the original's wxWidgets toolbar placement.

All `@Observable` classes are `@MainActor`; background work (spectrum FFT, WAV export) reads only main-thread snapshots; the audio render thread and meter tap are allocation-free (real-time audio rules).

## Layout

```
Sources/TranscribeRebuilt/
├── TranscribeApp.swift        App entry, scenes, menus, shortcut map, doc-open events
├── AppModel.swift             Coordinator: every user command (transport, markers, loops…)
├── TranscriptionDocument.swift  Document model: markers, text blocks, loops, FX, undo
├── AudioEngine.swift          AVAudioEngine graph (SourceNode→EQ→Varispeed→TimePitch→Dynamics→out),
│                              real-time render core (mix/loop/clicks), peak meter, transport
├── SpectrumAnalyzer.swift     vDSP FFT, note & chord guessing (per the original's help)
├── TranscriptionView.swift    Main window layout, waveform/marker/nav canvases, sheets, header bar
├── SpectrumView.swift         Spectrum graph + piano keyboard
├── LowerBarView.swift         Transport controls, sliders, time boxes, status
├── FXPanel.swift              The six FX pages (glass utility window)
├── XSC.swift                  .xsc read/write (byte-compatible grammar)
└── Panels.swift               Open/save/export panels, offline WAV renderer, About, Preferences
docs/rea-raw/                  Raw REA evidence (bundle inventory, Mach-O, menus, help book)
scripts/make-app.sh            Release bundle script (+ programmatic icon)
```

Transcribe! is Copyright © 1998–2026 Seventh String Software. This is an independent, personal-study rebuild; the reverse-engineering evidence and this code contain nothing from the original binary.
