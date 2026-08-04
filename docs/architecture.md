# Architecture

## Goals

1. **Native menu-bar app.** A normal `.app` bundle wrapping one executable, with a menu-bar control surface and no dock icon.
2. **Configurable activation.** Record any supported global shortcut and choose hold-to-talk or press-once-to-start/press-again-to-stop.
3. **Minimal recording feedback.** A small floating pill at the bottom of the screen while recording, so the user knows the mic is hot. Click-through, borderless, hidden when idle.
4. **On-device.** No network calls for transcription. Audio never leaves the machine.
5. **Memory-aware local inference.** Automatic detection and transcription use
   one multilingual model; model weights load lazily, expire after idle time,
   and release explicitly under memory pressure.
6. **Language-specialized models.** German remains an explicit specialist for
   users who select German directly; quantized Large variants remain selectable
   as per-device candidates.
7. **Learned vocabulary.** Compare the last inserted transcript with the user's
   in-place correction and persist a universal alias-to-canonical mapping.
8. **Native and lean.** One Swift Package executable target. No sidecar processes. No HTTP servers.

## Non-goals

- Cross-platform (macOS only)
- Dock icon or full preferences application
- Cloud transcription providers
- AI post-processing, summarization, agents
- Speaker diarization, meeting recording, semantic search
- A full preferences window (settings stay in the menu-bar popover)

## Why Swift

- **CoreML / ANE access.** WhisperKit and FluidAudio are Swift-native and run inference on the Apple Neural Engine — lower power, lower latency than CPU/GPU paths in Rust.
- **No FFI for platform APIs.** `AVAudioEngine`, `CGEventTap`, `CGEvent`, `AXIsProcessTrusted`, `NSWindow` — all first-party, no bindings to maintain.
- **Permissions plumbing** (microphone, accessibility) is dramatically smoother in a Swift binary than via Rust crates.
- **AppKit overlay for free.** The recording indicator (see below) is a borderless `NSWindow` — trivial in Swift, awkward in Rust.

The implementation remains a Swift Package executable. `scripts/build-app.sh`
wraps the release binary, the official whisper.cpp framework, and its
`Info.plist` in `Parrot.app`, then applies an ad-hoc local signature. It installs
the bundle but never launches it from the build process. There is no dock icon.

## High-level shape

```
$ parrot
                                    ┌──────────────────┐
                                    │   ParrotCLI      │
                                    │   (main.swift)   │
                                    └────────┬─────────┘
                                             │ wires modules, runs RunLoop
                                             ▼
┌──────────────────┐  hotkey down   ┌──────────────────┐
│   HotkeyMonitor  │ ─────────────▶ │  AudioCapture    │
│  (CGEventTap)    │  hotkey up     │ (AVAudioEngine)  │
└──────────────────┘ ◀───────────── └────────┬─────────┘
                                             │ [Float] PCM
                                             ▼
                                    ┌──────────────────┐
                                    │   Transcriber    │
                                    │   (protocol)     │
                                    │  ┌────────────┐  │
                                    │  │ WhisperKit │  │
                                    │  └────────────┘  │
                                    │  ┌────────────┐  │
                                    │  │whisper.cpp │  │
                                    │  └────────────┘  │
                                    └────────┬─────────┘
                                             │ String
                                             ▼
                                    ┌──────────────────┐
                                    │  TextInjector    │
                                    │   (CGEvent)      │
                                    └──────────────────┘
```

## Modules

### `main.swift` (ParrotCLI)

Argument parsing (via `swift-argument-parser`), config loading, module wiring. Calls `NSApplication.shared.setActivationPolicy(.accessory)` so the process has no dock icon and no menu bar entry, then runs `NSApp.run()` to keep the process alive and drive the AppKit run loop (needed for `NSWindow`, `CGEventTap`, and AVFoundation). Exits cleanly on SIGINT. Logs status to stderr so a user running it in a terminal can see what's happening.

Subcommands:
- `parrot` (default) — run the daemon
- `parrot models list` — show registered models, mark which are downloaded
- `parrot models download <id>` — pre-fetch a model
- `parrot doctor` — check microphone and accessibility permissions, print remediation steps

### `HotkeyMonitor`

Global hotkey via `CGEventTap` (requires Accessibility permission). Default: **hold Fn**. Modifier-only shortcuts are detected through `flagsChanged`; shortcut combinations use key-down/key-up events with exact modifier matching. Emits `.pressed` / `.released`. The menu-bar shortcut recorder persists the selection in the `com.digimata.parrot` user-defaults suite.

**Fn key caveat:** macOS by default maps the Fn (🌐) key to "Show Emoji & Symbols" or "Start Dictation" depending on the user's setting in System Settings → Keyboard → Press 🌐 key to. The CGEventTap sees the keypress regardless, but the system action also fires. `parrot doctor` will detect this setting and instruct the user to change it to "Do Nothing" so Fn becomes a clean modifier.

### `AudioCapture`

`AVAudioEngine` records 16 kHz mono `Float32` audio. Automatic and German modes
hand the completed buffer to the active transcriber. Fixed English mode uses
WhisperKit's live audio processor: it confirms segments privately during the
recording, cancels any stale in-flight whole-buffer pass on release, and
re-decodes only a short overlap plus the unresolved tail before injection.
Escape stops either capture path and discards all partial text.

### `Transcriber` (protocol)

```swift
protocol Transcriber {
    func transcribe(_ audio: [Float]) async throws -> String
    func warmUp() async throws
    func unload() async
    var modelID: String { get }
}
```

Concrete implementations:

- `WhisperKitTranscriber` — wraps WhisperKit for the shared multilingual
  detector/decoder, default full-size path, and explicit quantized candidates.
  CoreML/Metal-accelerated on the pinned compute path.
- `WhisperCppTranscriber` — wraps the official whisper.cpp XCFramework for the
  German fine-tuned GGML model. Metal-accelerated.

`TranscriptionService` owns the language router and model lifecycle. Automatic
mode detects the language from the finished recording, logs the existing
English/German confidence route, and then decodes with the same multilingual
pipeline using the detected language code. It therefore does not retain a
separate detector or specialist during Automatic mode. Selecting German
explicitly uses the pinned whisper.cpp specialist.

Every language mode records the complete utterance before starting one
full-context transcription. In Automatic mode, the finished recording first
goes through language detection and then a second decode on the same
multilingual pipeline. No provisional streaming segment can become part of the
delivered transcript.

WhisperKit warm-up includes three discarded seconds of silence after model
loading. This forces Core ML to compile its inference graphs before a model is
reported ready, without conditioning or retaining any priming transcript. The
app-bundle path does this lazily on the first transcription; the foreground CLI
still warms before entering its monitoring loop. A loaded model is evicted
after 60 seconds of inactivity, and `WhisperKit.unloadModels()` or
`whisper_free` is called before dropping the pipeline. Memory pressure defers
release until an active decode completes.

`RuntimeMemory.swift` samples RSS and physical footprint during model load and
transcription. Those peaks are written to stderr so model comparisons measure
the real process rather than relying on download-size estimates.

Adding an engine = one new file conforming to `Transcriber`.

### `TextInjector`

Before posting keyboard events, Parrot inspects the focused Accessibility
element and its parent chain. Native writable attributes, semantic text roles,
and Chromium contenteditable marker ranges all identify a valid target. This
handles custom Electron/WebKit editors that do not mark `AXValue` as settable.
Opaque controls that accept typing but expose no text metadata, including some
Word and Codex editor surfaces, receive an optimistic insertion attempt. Only
positively identified non-text roles trigger the clipboard fallback.
A valid target receives the transcript through `CGEventCreateKeyboardEvent` plus
`CGEventKeyboardSetUnicodeString`. Without one, Parrot puts the transcript on
the system clipboard and shows the same overlay capsule in a temporary **Copied
to clipboard** state rather than typing into an unrelated window.

The target application PID and the readable correction snapshot are captured at
hotkey release, before asynchronous transcription can change timing or focus.
Delivery is transactional: Parrot snapshots the existing clipboard, stages the
transcript with a guaranteed trailing separator space, and posts Command-V
directly to the captured PID rather than global
session focus. Readable fields are polled for the exact inserted span. Focused
opaque editor surfaces restore the prior clipboard after the paste-consumption
window even when they hide their content from Accessibility. For completely
opaque applications, the staged string uses a lazy pasteboard provider as a
consumption receipt: requesting the string through Paste proves delivery and
restores the prior clipboard. Unconsumed, non-text, and failed destinations
retain the transcript and show the clipboard pill. A newer user clipboard value
is never overwritten during restoration.

Before injection, `FocusedTextSnapshot` records the focused Accessibility text
element, insertion range, and short surrounding anchors. Pressing the Learn
hotkey within five minutes extracts the edited span, computes word-level
replacement hunks, and asks for confirmation. Selecting the corrected phrase
provides a fallback when an application does not expose its complete text value.
For custom web and Electron editors that hide both values from Accessibility,
Parrot temporarily invokes Copy on the selection or whole focused editor,
restores the clipboard, and fuzzy-aligns the edited field with the last
transcript.

### `CorrectionDictionaryStore`

Persists universal `recognized → canonical` mappings in Application Support.
Canonical terms prompt the compatible German specialist only after language
selection; aliases are then applied to every finished transcript using
case-insensitive, longest-first, Unicode word-boundary matching. The language
detector is deliberately never prompted by the dictionary.

### `RecordingOverlay`

A single borderless `NSWindow` displayed at the bottom-center of the active screen while recording. Provides visual feedback that the mic is hot — the only piece of UI in the app.

Window configuration:
- `styleMask: .borderless`
- `backgroundColor: .clear`, `isOpaque: false`, `hasShadow: true`
- `level: .statusBar` (or `.floating`) — sits above all other windows
- `ignoresMouseEvents = true` — clicks pass through to whatever is underneath
- `collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle]` — visible across Spaces, doesn't appear in window switcher

Content: a small SwiftUI view hosted via `NSHostingView`, showing a pulsing dot + "listening" text, optionally a live mic level meter fed from `AudioCapture`. Total footprint: ~120pt wide, ~40pt tall, positioned 60pt above the bottom of the screen.

States:
- **Hidden** — idle. No window on screen.
- **Recording** — shown on `.pressed`, mic level animated.
- **Transcribing** — brief spinner state between hotkey release and text injection (usually <500 ms).
- **Hidden** — back to idle after injection.

The recording overlay and menu-bar settings popover require the `NSApplication` run loop.

### `ModelRegistry`

Source-defined registry:

```swift
struct TranscriptionModel: Codable {
    let id: String              // "whisper-large-v3-turbo"
    let displayName: String
    let engine: Engine          // .whisperKit | .whisperCpp
    let sizeMB: Int
    let downloadURL: URL
    let languages: [String]
    let recommended: Bool
}

enum Engine: String, Codable { case whisperKit, parakeet }
```

The registry lives in `ModelRegistry.swift`; no sidecar resource is required.
Adding an engine requires a new `Transcriber` conformance and an `Engine` case.

The registry is the single source of truth for: download URLs, file names, sizes, recommended flags, what shows up in `parrot models list`, and the quantized/full-size fallback choices.

### `ModelDownloader`

WhisperKit manages its CoreML model cache. `GermanModelStore` downloads the
pinned German GGML asset to `~/Library/Application Support/Parrot/Models/`,
verifies its SHA-256 digest, and coalesces concurrent requests. The app only
prefetches the optional German specialist when the foreground CLI or a language
switch requests it; prefetching downloads to disk but does not load that model
into RAM. The active multilingual model is selected from the WhisperKit
hardware catalog, with the full Turbo checkpoint retained as an explicit
fallback.

### `DictationSettings`

Persists the shortcut, activation mode, and language in the legacy
`com.digimata.parrot` user-defaults suite so the clean 0.2 app identity keeps
existing user settings. Defaults remain Fn + Hold + Automatic.

### `MenuBarController`

Owns the status item and transient AppKit popover. It displays current state/model, records shortcut combinations or modifier-only keys, switches between Hold and Toggle behavior, controls the `SMAppService.mainApp` launch-at-login registration, and provides Quit.

## Permissions

Two prompts on first run, both surfaced via `parrot doctor`:

1. **Microphone** — standard `AVCaptureDevice` request, fires on first audio engine start.
2. **Accessibility** — required for `CGEventTap` (hotkey) and `CGEvent` posting (text injection). User toggles in System Settings → Privacy & Security → Accessibility, granting the *terminal* (or whatever launched parrot) permission, since the binary inherits its parent's TCC identity.

`parrot doctor` checks both and prints actionable next steps if either is missing. Without these, the daemon refuses to start.

### TCC quirk worth knowing

When you launch `parrot` from `Terminal.app`, accessibility permission is granted to *Terminal*, not parrot itself. This means:
- Switching terminals (Terminal → iTerm → Ghostty) requires re-granting permission.
- Running under `launchd` requires granting permission to whatever spawns it.

This is a macOS platform behavior, not a parrot bug. `parrot doctor` will identify the parent process and tell the user which app needs the permission.

## Models — what ships

Initial registry:

| Engine | Model | Size | Notes |
|---|---|---|---|
| WhisperKit | `whisper-large-v3-quantized` | ~626 MB | Quantized Large candidate; benchmark per device |
| WhisperKit | `whisper-large-v3-turbo-quantized` | ~632 MB | Quantized Turbo choice where the hardware catalog advertises it |
| WhisperKit | `whisper-large-v3-turbo` | ~1.62 GB | Default full-size multilingual quality path |
| whisper.cpp | `whisper-large-v3-turbo-german-q5` | ~548 MB | German specialist |
| WhisperKit | `whisper-base.en` | ~145 MB | Optional compact English CLI model |

Models are not bundled. WhisperKit uses its own cache; the German GGML model
lives under `~/Library/Application Support/Parrot/Models/`.

## Data flow, end-to-end

1. User opens `/Applications/Parrot.app`.
2. `ParrotCLI` validates permissions (`parrot doctor` logic), loads config, instantiates modules.
3. Sets `.accessory` activation policy and enters `NSApp.run()`. Status: `listening`. Overlay hidden.
4. User holds Fn.
5. `HotkeyMonitor` fires `.pressed`. `RecordingOverlay` shows. Status: `recording`.
6. `AudioCapture` starts the AVAudioEngine tap. Buffers fill. Overlay animates mic level.
7. User releases Fn.
8. `HotkeyMonitor` fires `.released`. Overlay switches to spinner. Status: `transcribing`.
9. `AudioCapture` stops and hands the buffer to `TranscriptionService`.
10. Automatic mode detects the language and decodes with the same multilingual
    model using the detected language code.
11. `TextInjector` posts the string at the cursor.
12. Overlay hides. Status: `listening`. Loop.
13. User chooses **Quit Parrot** from the menu-bar popover.

English and Automatic share the full Turbo multilingual model by default. The
quantized Large variants are explicit per-device candidates because smaller
download size did not lower this M1 Pro's measured physical footprint. The
German specialist trades additional disk/RAM residency when that language is
selected directly.

## What we are deliberately NOT building

- No streaming partial transcripts in v1. Press, speak, release, get full text.
- No VAD-based hands-free mode. Push-to-talk is more reliable and uses zero idle CPU.
- No history, transcript log, or clipboard manager. Output goes to the cursor and that's it.
- No custom vocabulary, prompts, or post-processing.
- No full preferences window or transcript/history UI. Configuration stays intentionally limited to the compact menu-bar popover.

These are deliberate cuts. Each can be revisited if real usage demands it.

## Project layout

Organized by feature area. These are folders within a single SPM executable target — Swift sees them as one module, but the directory grouping keeps related code together. If a group later earns its keep as a reusable library (e.g. `Transcription` consumed by another tool), it can be promoted to its own SPM target with no rewriting.

```
parrot/
  Package.swift                 # SPM, single executable target
  Sources/parrot/
    Parrot.swift                # entry point, argument parsing, NSApp.run()
    AppIdentity.swift           # bundle and status-item identities
    Doctor.swift

    Transcription/              # the inference layer
      Transcriber.swift         # protocol
      WhisperKitTranscriber.swift
      WhisperCppTranscriber.swift

    Models/                     # source-defined registry
      ModelRegistry.swift
      TranscriptionModel.swift  # Codable types

    Audio/
      AudioCapture.swift        # AVAudioEngine tap + ring buffer

    Input/
      CorrectionLearning.swift  # focused-field snapshot + correction diff
      HotkeyMonitor.swift       # CGEventTap
      TextInjector.swift        # CGEvent posting

    Vocabulary/
      CorrectionDictionary.swift

    UI/
      RecordingOverlay.swift    # borderless NSWindow + SwiftUI pill
      MenuBarController.swift   # status item and compact settings

  App/
    Info.plist
  docs/
    architecture.md
  README.md
```

Build/install the app with `scripts/build-app.sh`. For CLI use, the release
binary remains available at SwiftPM's release binary path.

### On Swift "modules"

Swift's module unit is the **SPM target** (one target = one module = one `import` namespace). For parrot v1 we use a single executable target with the folder structure above; everything is in the same module so no `import` statements between files. If we ever want enforced boundaries (e.g. `Transcription` and `UI` shouldn't reach into `Audio` internals), we promote folders to separate targets in `Package.swift` — a structural change, not a semantic one.

## Packaging constraints

The local bundle is ad-hoc signed, so each rebuild resets Microphone and
Accessibility consent. The build script intentionally stops after installation:
the user launches the new app from `/Applications`, which prevents the status
item from being attributed to the build host. The standalone CLI is headless
and never creates a second menu-bar status item.
