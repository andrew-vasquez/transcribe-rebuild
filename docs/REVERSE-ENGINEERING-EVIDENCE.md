# Transcribe! 9.70.1 — Reverse-Engineering Evidence Report

**Target:** `/Applications/Transcribe!.app` (Seventh String Software, "Transcribe!" v9.70.1, © 1998–2026)
**Date:** 2026-10-09 · **Method:** REA (reverse-engineer-anything) evidence-based workflow
**Goal:** Understand the whole application, then rebuild it from the ground up as a Tauri application in this repo.

---

## 0. Methodology and tooling honesty

The REA MCP server was connected but its deep native providers (Hopper bridge, Ghidra, IDA) were **unavailable** in this environment — the Hopper bridge startup timed out (the installed Hopper at `~/Applications/Hopper Disassembler.app` never loaded the document), Ghidra was not configured, and IDA was not registered. **No decompilation or pseudocode was produced.** All conclusions below come from:

1. **REA provider-independent tools** (fresh CLI sessions): `inspect-artifact`, `inspect-macho`, `inspect-signature`, `list-architectures` — each returns signed Evidence records with provenance (`file`, `lipo`, `otool`, `nm`, `dyld_info`, `dwarfdump`, `vtool`, `codesign`).
2. **The application's own bundled documentation** — `Contents/Resources/xschelp.htb` is a ZIP archive of 71 HTML help pages documenting every feature in the developer's own words. Extracted to `docs/rea-raw/xschelp/` (text: `docs/rea-raw/xschelp-txt/`).
3. **Runtime observation** — the app was launched (it restored the user's last session), its complete menu bar was dumped via the macOS Accessibility tree (System Events), and it was quit again. No user documents were modified. Screen recording was **denied** by macOS TCC, so no screenshots were taken (the help book's own window-layout image `docs/rea-raw/xschelp/layoutmac.png` documents the UI instead).
4. **Read-only shell tools** on the shipped artifacts (`otool -L`, `strings`, `plutil`, `ls`).

Every claim below is labeled **[O] observed**, **[I] inferred**, or **[U] unknown**, per REA methodology.

### Evidence ledger (REA Evidence records)

| Evidence ID | Operation | Authority | Confidence | Coverage |
|---|---|---|---|---|
| `ev_8e23a91d1b8de9977ba00eb44d12b1728a5dd621029d4dbf192e0c87cfd9bfd7` | `inspect_artifact` (bundle inventory) | shipped-artifact | observed | 1,043 artifact observations, 439 relationships, coverage "complete-within-substeps" |
| `ev_fe4c1dc710977a675423b19c848662dddf70eebfee3bb9ba69a0c7375e26f42f` | `inspect_macho` (main executable) | shipped-artifact | observed | all load commands, segments, deps, imports/exports; provenance: file/lipo/otool/nm/dyld_info/dwarfdump/vtool |
| `ev_3586892bee388ad0422fad88edb2961090db74d9cd21030f53afc49326010565` | `inspect_signature` | shipped-artifact | observed | codesign -d verbose=4: identity, entitlements, hardened runtime |
| (open_binary identity) | target binding | — | observed | Mach-O arm64, SHA-256 `83594347cfde8aadf300b9e11b71d69af9883e4e6f9af86c150c1b9626bd32d0` |

Raw evidence files: `docs/rea-raw/inspect-artifact.json`, `inspect-macho.json`, `inspect-signature.json`, `menu-dump.txt`, `observe-ui-*.json`, `xschelp*/` (extracted help book).

---

## 1. Target identity

- **[O]** Mach-O 64-bit ARM64 (thin, single architecture), main executable `Contents/MacOS/Transcribe!`, 8,381,344 bytes, SHA-256 above, build UUID `31CB6C8A-7437-3D4E-9D17-FCD9EB490C69`.
- **[O]** `Info.plist`: `CFBundleIdentifier = com.seventhstring.transcribe`, `CFBundleShortVersionString = 9.70.1`, `CFBundleGetInfoString` "Transcribe! 9.70.1, Copyright 1998-2026 Seventh String Software", `LSMinimumSystemVersion = 13.0`, `LSApplicationCategoryType = public.app-category.music`.
- **[O]** Build metadata (vtool/otool): platform macOS, **minimum OS 13.0, SDK 14.2**, Xcode toolchain 1022.1 (Xcode 16 era).
- **[O]** Code signature: **Developer ID Application: Seventh String Ltd (BLF9LDX5CW)**, hardened runtime enabled, signed 2026-09-30.
- **[O]** Entitlements: `automation.apple-events`, `allow-dyld-environment-variables`, `allow-unsigned-executable-memory`, `disable-library-validation`, `device.audio-input`. **[I]** The latter three exist to load the bundled GStreamer dylibs and `Contents/Plugins/*.so`; `audio-input` is for the Record feature; `apple-events` supports its AppleScript/automation support (`NSAppleScriptEnabled = YES`).
- **[O]** Document types it owns: `.xsc` ("Transcribe! transcription document", Editor role) and `.xscscpt` ("Transcribe! script file", Viewer role); it registers as Viewer for ~28 audio/video UTIs (mp3, aiff, wav, ogg, flac, m4a, mp4, avi, wma, flv, dv, 3gpp…).

## 2. Not Electron — a native C++ wxWidgets application

The request assumed an Electron app. The shipped artifact proves otherwise:

- **[O]** `NSPrincipalClass = wxNSApplication` (wxWidgets' macOS app class) in `Info.plist`.
- **[O]** `otool -L`: links `libc++.1.dylib` (C++), system frameworks only — **no Electron, no Node, no Chromium, no ASAR** anywhere in the 404-file bundle (verified by `find` for `*.asar`, `*.node`, `Electron*`, `*.js`).
- **[O]** `inspect_macho` exports include statically-linked wxWidgets C++ symbols, e.g. `__Z31wxDictionaryStringSortAscendingRK8wxStringS1_`, `__Z9wxUIntCmpjj`. **[I]** wxWidgets is compiled into the binary statically (no dynamic wx library in `otool -L`).
- **[O]** Drawing stack: linked frameworks `OpenGL`, `QuartzCore`, `CoreGraphics`, `CoreText` — **[I]** the waveform/spectrum/piano UI is custom-drawn, which matches the shallow accessibility tree observed at runtime (window exposes only its title-bar controls; all content is one custom-drawn surface).

So "instead of Electron" translates in practice to: *replace a hand-written native wxWidgets/GStreamer desktop app with a Tauri 2 (Rust + WebView) app.*

## 3. Technology stack (all observed in shipped artifacts)

| Concern | Technology | Evidence |
|---|---|---|
| Language | C++ (libc++) | `otool -L`, mangled exports `[O]` |
| GUI toolkit | wxWidgets (statically linked) | `NSPrincipalClass` `[O]`, exports `[O]` |
| Media (decode/playback, video) | Bundled **GStreamer 1.24.x** framework (`libgstreamer-1.0.0.dylib` version 2808) at `Contents/Frameworks/GStreamer.framework` | `otool -L` `[O]`, `inspect_artifact` `[O]` |
| Media fallbacks | Native readers first, then GStreamer, then **AVFoundation/AVFAudio** | help `gstreamer.htm` + linked AVFoundation/AVFAudio `[O]` |
| Audio I/O | CoreAudio / AudioToolbox / AudioUnit | `otool -L` `[O]` |
| DSP math | **Accelerate** (vDSP) | `otool -L` `[O]`, help describes DFT spectrum `[O]` |
| MIDI input | **CoreMIDI** | `otool -L` `[O]`, help `midi.htm` `[O]` |
| Compression encoding | GStreamer elements found in binary strings: `lamemp3enc` (mp3), `voaacenc` (AAC), `x264enc` (H.264), plus `audioconvert`, `audioresample`, `decodebin`, `videoflip`, `videoscale` | `strings` on main binary `[O]`; matches help: video export is "always mp4 with aac-encoded audio and H264-encoded video" |
| Subtitle parsing | GStreamer plugins bundled in `Contents/Plugins/`: `libgstsubparse.so`, `libgstvideosection.so` | bundle listing `[O]` |
| Help | `xschelp.htb` = ZIP of HTML (71 pages) | extracted `[O]` |
| Helper apps | `Contents/Resources/THV/` (Transcribe Help Viewer) and `TVV/` (Transcribe Video Viewer) sub-bundles with own Info.plist/icons — separate processes for help and video playback | bundle inventory `[O]`, help: "Help Viewer and Video Viewer are effectively different applications" |

**Bundle layout [O]:** `Contents/{MacOS/Transcribe!, Frameworks/GStreamer.framework (≈380 files), Plugins/ (2 .so), Resources/ (help book, app icons XSCAPPICN/XSCDOCICN, THV, TVV, English.lproj), _CodeSignature, Info.plist, PkgInfo}` — 404 files total.

## 4. Complete feature inventory (from the app's own help + runtime menus)

The 71 help pages document the application exhaustively. Summary with citations (all `docs/rea-raw/xschelp-txt/…`):

### 4.1 The transcription window (`gs_window.txt`, layout `[O]` + help image)
Top→bottom: title bar (shows **xsc name** + "•" when modified) → toolbar → marker zone (triangles + labels; red triangle = current point) → text zone (optional) → **waveform** (stereo = left above/right below; selection highlighted; play position indicator line; parts not yet read shown as yellow band) → custom **scroll bar** (shows play position; ctrl-drag = horizontal scale; shift-drag = vertical scale) → **navigation bar** (full-length overview, sections/measures, click to jump; ctrl-click = "go to marker" menu; optional time line & loop line) → splitter → **spectrum** (point/selection/live, chord-guess readout at top right) → **piano keyboard** (clickable; MIDI C0–C8 naming with C4 = middle C; note-centre lines rising into the spectrum; green/red note-guess blobs) → **lower toolbar** (horizontal scale slider, volume slider + compressor red bar, "Now Playing" & "Track Length" boxes, Play/Pause/Stop/Review/Cue/Go-To-Start/Go-To-End buttons, speed slider 20–100% (200% if window wide), semitone pitch slider (+cents if wide), "Current point" & "Selection length" boxes — all editable text boxes with m/s parsing and nudge keys).

### 4.2 Playback engine (`play_menu.txt`, `prefs_playback.txt`, `fx_speed.txt`, `slow.txt`)
- Play (selection else from current point), Pause/Resume, Stop; loop mode; **loop delay** (pause between repeats, 0–100 tenth-seconds); scroll-follow mode; metronome **clicks at markers** (volume in Misc page; "recorded from a genuine old wooden metronome").
- **Cue/Review** (fast fwd/rew): accelerates 4×→20× over 8s by default, separate volume (60% default), can be restricted to the playing zone.
- **Scrubbing**: mouse wheel, `O`/`P` keys, MIDI controller (center = pause). Plays at current speed, pauses 0.75s after wheel stops.
- **Speed: 5%–200%**, 3-decimal precision, presets + toolbar buttons + type-in + mousewheel + shortcuts + MIDI + script. Two algorithms: standard and **HQ slowdown** ("new method… better, especially in the handling of transients when slowing down"). **Analog lock** (speed/pitch interlocked like tape — cheaper, fewer artifacts).
- Output always resampled to **44100 or 22050 Hz**; buffer 0.2–1.0s (default 0.4); compressor/limiter to prevent digital overload (red bar under volume); rewind-on-pause; playback start delay; paused-point-follows-selection; keep-playing-in-background; auto-play on load.
- Tuning/pitch shift: **octaves + semitones + cents sliders (±3 octaves, in cents)**; A=440 reference with "becomes X Hz" display; reference-note player (triangle/square wave, asymmetry, volume). **Transposition** page (reference-pitch naming for transposing instruments: Bb trumpet, capo, etc.) affects piano/reference notes/spectrum naming only.

### 4.3 Audio effects (`fx.htm`, `fx_eq.txt`, `fx_mix.txt`, `fx_tuning.txt`, `fx_misc.txt`)
The "Audio Effects and Controls" window has 6 tabbed pages, applied **in page order** (Mono/Karaoke → EQ → Tuning → Transposition → Speed → Misc): each page has Clear/Active/Bypass and "apply to all views". The waveform profile always shows the *original* data; the spectrum follows the effects.
- **Mono/Karaoke**: per-channel mix proportions (same signal in both ears, not a balance control); out-of-phase "karaoke" mix cancels center-panned material; disabled for mono files.
- **EQ**: **31-band graphic EQ, ⅓ octave per band**, +20dB → −20dB smooth, then drastic to **−80dB** (band removal); elastic neighbouring-slider drag (shift accelerates, ctrl-click disables); dB-accurate volume when only gain is used; global named presets (14 shipped defaults: Tenor, Soprano…) stored in Preferences, with Load/Save/Rename/Defaults/Delete/Export/Import; overload protection via compressor.
- **Misc**: per-view volume (always active), clicks volume, **stored loops** (20+ buttons, store/recall position+selection and optionally full Fx settings, names, colors, location indicators, reorder; `LoopStore1..20`/`LoopRecall1..20` commands), and selection-move buttons (by beat/measure/end; shift = grow, shift+cmd = shrink).

### 4.4 Markers (`markers_menu.txt`, `prefs_markers.txt`)
- Types: **Section / Measure / Beat** + auto-generated **subdivisions** (red ticks, not editable). Labels above triangles in the marker zone. Current point = red triangle (undeletable).
- Placement while playing: `S`/`M`/`B` keys (tapping in time; a section marker replaces the first measure, a measure marker replaces the first beat); silent variants `Shift-S/M/B`; latency compensation preference shifts placements earlier.
- Editing: double-click = edit/create; drag = move; Alt = copy; Cmd-drag = move/copy many (whole selection); ctrl-click popup menus; **snap-to-marker** selection with Option key; **Delete Selected Markers** (in selection); **Equally Space Selected Markers**; **Compute Tempo** (counts markers, divides duration → BPM of original and altered speed, warns if uneven).
- Auto-labelling: sections "A, B, C…", measures "A2, A3…" resetting at sections (or continuous numbering), beats unlabelled by default; label override (e.g. "Verse 3 (92)" resets numbering); per-marker subdivision setting (same-as-previous / no / N).
- Markers are **undoable**; exported (with text blocks) to UTF-8 text; navigation bar shows sections (measures optional).

### 4.5 Selection & current point (`cmnddoc_selection.txt`, `kb.txt`)
Hundreds of commands: move/increase/decrease selection at either end by pixel/30ms/100ms/500ms/1s/2s/…, by beat/measure/section/end; `J`/`K`/`L` create 0.1/0.2/0.3s centered selections for instant note looping; `1–4` set current point back 10/5/2/1s; `U`/`I` collapse selection to left/right edge; `E` sets current point to the playing point; `D` selects current-point→playing-point.

### 4.6 Spectrum, note & chord guessing (`spectrum.txt`, `guess.txt`, `gs_window.txt`)
- **Point spectrum**: 0.25s window centered on the current/paused point; **selection spectrum**: first second of selection; **Live Spectrum**: follows playback (preference). Mono-downmix (or Mono/Karaoke proportions) is used for spectrum computation. Auto vertical scaling by default, or fixed (preference); dB calibration lines; click = harmonic grid (5 octaves each side) + pitch/frequency readout; ctrl-drag spectrum = tune; shift-ctrl-drag = transposition.
- **Note guessing**: peak-picking with harmonic discounting (magnitude-relative); green centered blobs (in tune) vs red offset blobs (out of tune); blob size = confidence.
- **Chord guessing**: matches note set against known chord types, best match first; low notes weighted; may discard high notes; Cmd-click greys notes out; conventional chord symbols incl. slash chords ("C/E"), never "F/B"-style non-chord bass; minor only if minor 3rd present; "b13", "dim" vs "dim7" conventions documented; enharmonic alternates offered in popup; guesses insertable into the text zone.
- **Piano Roll view** (`pianoroll_menu.txt`): whole-track note guesses left→right beside the waveform, thickness = confidence, darkness = volume; computed from a straight mono mix (unaffected by EQ/Mix); computed in background ("yellow band" while incomplete); click = identify note, shift-click = chord guesses, ctrl-click = insert chord as text block; sensitivity controls; optional piano at left.

### 4.7 Files (`file_menu.txt`, `sound.txt`, `xsc_files.txt`)
- **Open** a sound file (starts new transcription) or an existing `.xsc` (restores); Save/Save As; up to 32 **Recent Files/Folders**; **Import Sound File** (re-link/replace, remembers previous); **Record New Sound File** (input selector, VU meters, margin dB, auto-stop, WAV/AIFF/compressed); **Stem Files** (associate multiple sound files with one transcription, switch preserving markers; selector bar); **Export Sound File** (whole/selection; N repetitions; choose which effects apply incl. HQ slowdown; WAV/AIFF/compressed; sample-rate choice incl. 44100 for CD); **Export Split Sound File** (split by section/measure markers into numbered/named files — the developer's vinyl-splitting tool); **Export Video / Split Video** (always mp4/H264/AAC "with frequent key frames"); **Export Markers and Text Blocks** (UTF-8 text, BOM option, word wrap, per-color selection).
- **Never modifies sound files** — all effects are computed on the fly; exports are explicit new files.
- Formats natively read: **WAV, AIFF/AIFC, MP3 (MPEG-1/2 Layers II & III), OGG Vorbis, FLAC**; everything else via **GStreamer**; then **AVFoundation**; DCT dictation wrapper split into text+WAV; no DRM (M4P etc.); no MIDI files by design.

### 4.8 Transcription documents — `.xsc` format (`xsc_files.txt`) [O]
Plain **comma-delimited UTF-8 text**, mnemonic sections:
- `[Main]`: `SoundFileName` (short/long), `SoundFileInfo` (format, channels, bytes, sample rate, sample count, duration)
- `View0`, `View1`…: per-view FX settings
- `[Markers]`: `Howmany,N` then rows `S|M|B, sample(-1 = use timestamp), autoLabel?, label, subdivision(0=same,1=none,N=N), h:mm:ss.ffffff` (v9+ uses −1 + 6-decimal timestamps)
- Text blocks: `T, pos, vpos, width(px), color, timecode, text`; escaping: `,`→`\C`, `\`→`\\`, newline→`\n`
Same file on Windows/Mac/Linux. Cross-platform compatible.

### 4.9 Text blocks (`text_menu.txt`)
Text zone strip above the waveform; arbitrary multi-line text blocks anchored at left edge; per-block colors; active block with handles (width, auto height; move constrained with Cmd); Alt-drag copies; multi-select via waveform selection (black stripe); font per-transcription; `T` shortcut; insert chord guesses; export filtered by color; undoable.

### 4.10 Input control surfaces
- **Keyboard shortcuts** (`kb.txt`, `kb925.txt`): fully configurable; hundreds of named commands (`PlayPauseOn`, `RecentFile7`, `LoopRecall6`, `SelectionIncreaseRightMeasure`…); per-shortcut press & release commands; defaults include Spacebar play/pause, `.` stop, `,` pause, `C`/`R` cue/review, `O`/`P` scrub, `A` loop A-B, `Cmd-L` loop, `Cmd-R` scroll, `Cmd-1..4` speeds, `Cmd-7..0` ±3/±1%, `Z` play-while-held, `;` progressive play, `-`/`=` volume, `S/M/B` markers, `T` text, arrows/`[`/`]` selection moves, `E/D/U/I/J/K/L`, `1-4` seek-back, `Q/W` scroll-into-view, `Cmd-arrows` zoom, `Cmd-G/F` fit; **global shortcuts** (active when app is background, incl. Numpad/Control modifiers on Mac); export/import.
- **MIDI** (`midi.txt`): CoreMIDI input; note/cc/program-change events mappable like key presses (press/release; program change = press+immediate release); **continuous control** of speed/volume/scrub with min/max response mapping; relative-mode endless knobs (e.g. Axiom) map specific values to commands; invert; respond never/foreground/always.
- **Foot pedals** (`footpedal.txt`, `vidami.txt`): HID/joystick pedals (e.g. VPedal), keyboard-emulating pedals, Apple IR remote; quick-setups for 1/2/3-button pedals + Vidami 5-button (10 commands via short/long press); per-pedal press/release commands; auto-repeat; export/import.

### 4.11 Automation (`automation.txt`, `cmnddoc_*.txt`) [O]
`.xscscpt` plain-text script files (UTF-8): semicolon-terminated command list, `#` comments, parameterized commands e.g. `SpeedIncrement(0.01);`, `FileOpenNamed("+F")` (self-call recursion); escapes `++ +\" +n +/ +H +D +S +N +F`; no loops/conditionals/variables; `ScriptWait`, `ScriptAbort`; any manual command aborts a script; batch processing from the command line. The `cmnddoc_*.txt` pages enumerate ~700 command names across app/files/fx/looping/markers/playing/selection/textblocks/view categories.

### 4.12 Windows & preferences (`window_menu.txt`, `app_menu.txt`, `prefs_*.txt`)
- Multiple transcription windows; one shared **Audio Effects and Controls** window and one **Transcription Info** window (operating on the front transcription); split views (2+ per window, per-view FX, synchronize scroll); Mac-style "close last window leaves empty new transcription" behavior (preference).
- Preferences: General (session restore, reduced CPU, live spectrum, compute piano roll while playing, tooltips, recent list sizes 32 max, middle C naming C3/C4/C5, DPI, spectrum vertical scale, wheel sensitivity, label keys), New Windows (set defaults from current window), Playback (above), Export (compression presets mp3/m4a/vorbis HQ≈256k/MQ≈128k, custom GStreamer pipelines, video bitrate MB/min limit, timestamped filenames), Markers (auto-labelling, latency), Fret Display (stringed-instrument note lookup for ctrl-click), Toolbar (choose speed buttons etc.). Stored as INI in `~/Library/Preferences/Transcribe!7 Preferences` **[O]** (sections seen: `[General_U]`, `[PresetsEQ_U]`, `[KbShortcuts_U]`).

### 4.13 Runtime menu dump [O] (`docs/rea-raw/menu-dump.txt`)
Launched app restored the user's last session (window titled `Transcribe! - <name>.xsc` — evidence for session-restore preference). Complete menu bar dumped with enabled states matching the docs, including per-context enablement (e.g. *Show Video*, *Select Sound Track*, *Fit Selection*, *Undo/Redo* disabled in the observed state; File menu shows all 12 export/import/record/stem commands; View menu shows all 22 items; PianoRoll & Text menus present).

### 4.14 DSP architecture [I from multiple O sources]
Playback pipeline **[I]**: file reader (native → GStreamer → AVFoundation) → decode to PCM → Mono/Karaoke mix → 31-band EQ → pitch shift (tuning) → time-stretch/resample (speed; HQ vs standard algorithm; analog lock = simple resample) → compressor/limiter → volume → output resample to 44.1/22.05k → CoreAudio. Spectrum computed via vDSP FFT on the post-Mix (and pre/post-EQ — help says EQ affects spectrum, speed/tuning shift its frequencies appropriately). The **exact HQ time-stretch algorithm is [U]** — not recoverable without decompilation; the rebuild will use a high-quality phase-vocoder/WSOLA-class stretcher (documented deviation).

---

## 5. Observations / Inferences / Unknowns

**Observations:** everything marked [O] above — bundle layout, linkage, signature, entitlements, help-book contents, menu dumps, prefs file existence/sections, window behavior at launch/quit.

**Inferences:** DSP chain order (from help text describing effect order and spectrum behavior), reason for entitlements, wxWidgets static linking (exports present, no dynamic lib), helper-bundle purposes (THV/TVV named for Help/Video viewers and corroborated by help text).

**Unknowns (bounded):**
1. Exact HQ slowdown/pitch-shift algorithm internals (needs decompilation; Hopper/Ghidra unavailable here).
2. Note/chord guesser thresholds and the chord-type match table (behavior documented; constants not).
3. Video window internals (GStreamer pipeline specifics).
4. THV/TVV helper binaries' contents (not analyzed individually; roles documented).
5. Whether spectrum EQ interaction happens pre/post EQ (help: EQ affects spectrum → post-EQ pre-speed **[I]**).
6. No screenshots (Screen Recording TCC denied to REA host); UI confirmed via AX tree + help images instead.

---

## 6. Rebuild plan — Tauri 2 ("Transcribe Rebuilt")

**Stack:** Tauri 2 (Rust backend + system WebView frontend), TypeScript + Vite + vanilla-DOM/canvas frontend (this app is a custom-canvas UI; a framework would fight it), Rust audio core:

| Original | Rebuild |
|---|---|
| Native readers + GStreamer + AVFoundation | `symphonia` (WAV/AIFF/MP3/OGG/FLAC/AAC/ALAC/M4A…) in Rust |
| CoreAudio output | `cpal` (44.1kHz, f32) |
| vDSP FFT spectrum | `rustfft` |
| HQ slowdown / pitch shift (algorithm unknown) | Rust time-stretcher (phase-vocoder/WSOLA) + resampler; **analog lock** = plain resampling — identical behavior contract |
| 31-band EQ, compressor, channel mix | Rust DSP module |
| wxWidgets custom UI | Canvas-rendered waveform/spectrum/piano + DOM toolbars |
| `.xsc` session files | **Read & write real `.xsc`** (format fully documented above) — sessions interoperate with the original app |
| INI preferences | JSON config via `tauri-plugin-store`-style config file |
| GStreamer video, MIDI, pedals, scripts, recording, stems | Roadmap (documented gaps for v1) |

**v1 scope (the transcription core):** open/recent/drag-drop audio; waveform (stereo split, h/v zoom, fit, scroll-follow); selection + current point + play position; play/pause/stop/resume, loop, loop delay; speed 5–200% with pitch preservation + analog lock; tuning (octaves/semitones/cents); 31-band EQ + compressor + volume; mono/karaoke mix; markers (S/M/B + labels + auto-labelling + subdivisions + edit/move/delete + equally-space + compute tempo + clicks); text blocks; stored loops (20+, names/colors); spectrum (point/selection/live) with piano keyboard, harmonic grid, note & chord guessing; navigation bar; time line; the default keyboard-shortcut map; save/load `.xsc`.

**Documented deviations:** no video, no MIDI/pedal input, no scripting, no recording, no stems, no split views, no piano roll, no global shortcuts, no mp3 export (WAV/AIFF export only) — each is listed in the README roadmap with the original's help page as the spec to implement against.

---

*Evidence files preserved under `docs/rea-raw/`. This report cites the shipped artifacts, the application's own help documentation, and runtime observation; it contains no decompiled code.*
