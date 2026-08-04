# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

## Build and run as an app

```sh
./scripts/build-app.sh
open /Applications/Parrot.app
```

This creates a native menu-bar application at `dist/Parrot.app` and replaces
the validated Parrot bundle at `/Applications/Parrot.app`. Because local
ad-hoc signatures change on rebuild, the script resets Accessibility and
Microphone consent. It deliberately does not launch the app from the build
session: open `/Applications/Parrot.app` yourself so macOS attributes the
menu-bar item and its permissions directly to Parrot. Re-enable the permissions
when macOS prompts. Enable **Launch Parrot at login** from the menu-bar popover.

## Command-line install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs locally through CoreML/Metal, so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

## How to use

1. **Run it.** Open `Parrot.app`, or run `parrot` in a terminal.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot. Press **Escape** to cancel and discard the recording. Click the Parrot menu-bar icon to record a different shortcut or switch to **Toggle** (press once to start, once again to stop).
4. **The transcript types itself in at the cursor** when you release, followed
   by one separator space so the next dictation continues naturally. Parrot
   records the complete utterance and starts one full-context transcription
   after you release the shortcut. This avoids committing provisional streaming
   segments or losing words at the recording boundary. Parrot recognizes native,
   web, Electron, and opaque custom editors. Positively identified non-text
   controls copy the transcript to the clipboard and show a brief
   **Copied to clipboard** pill instead of sending keystrokes to the wrong place.
   The destination application is captured when recording stops, so a delayed
   transcript cannot be redirected by Cmd-Tab or overlay focus. Parrot stages a
   clipboard backup and sends Paste directly to that application. It restores
   the previous clipboard after readable fields confirm the exact inserted text,
   Accessibility identifies a focused opaque editor, or an opaque application
   consumes the staged transcript through its Paste handler. Only unconsumed,
   non-text, or failed destinations retain the transcript and show the pill.

That's it. There is no record button or "send" button—the configured global shortcut is the recording control.

## Learn names and specialist vocabulary

Parrot has one universal correction dictionary shared by English, German, and
Automatic mode. To teach a spelling:

1. Dictate normally and let Parrot insert the transcript.
2. Correct the misspelled word or phrase in place.
3. Press **Control–Option–L** (configurable as **Learn** in the menu-bar settings).
4. Confirm the extracted `recognized → corrected` mapping.

For example, changing `spectra easy` to `Spectreasy` teaches Parrot to replace
that recognition next time. Learned aliases are applied deterministically to
both English and German output; the German specialist also receives canonical
spellings as prompt vocabulary. The dictionary is never supplied to
the automatic language detector.

Open **Dictionary…** in the menu-bar settings to add, edit, or remove mappings.
Entries are stored locally at
`~/Library/Application Support/Parrot/Dictionary/corrections.json`.

The **Language** setting supports English, German, or Automatic recognition.
Automatic and English now share one multilingual Whisper Large model: it detects
the language and performs the final decode through the same loaded pipeline. On
this M1 Pro, full Turbo remains the default quality-preserving choice: its
measured physical footprint was about 2.2 GB at peak, versus about 3.7 GB for
the 626 MB quantized candidate during Core ML specialization. Both quantized
Large artifacts remain registered for explicit per-device benchmarking. German
remains available as an explicit 548 MB whisper.cpp specialist. This avoids
keeping a detector, English model, and German model resident at the same time.

The app loads the model lazily when the first recording is transcribed, keeps it
hot for roughly 60 seconds after the last job, then explicitly releases the
Core ML/Metal weights. macOS memory pressure releases them sooner. A dictation
after eviction may take longer while the model is loaded and Core ML is primed;
repeated dictations inside the idle window stay warm. Audio remains on the Mac;
only model downloads use the network.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If you keep Fn as your shortcut and it is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # full-size multilingual quality path
parrot --no-overlay                    # disable the bottom-of-screen pill
```

To compare model memory, latency, and output on local recordings:

```sh
bash scripts/benchmark-models.sh /path/to/recording.wav
```

The benchmark preserves all model files and prints the `memory ... peak ...`
measurements emitted by Parrot. A speech corpus is required to make a quality
claim; the script does not treat latency or model metadata as a transcription
accuracy result.

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **whisper.cpp** — German specialist inference via Metal
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
