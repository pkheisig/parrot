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
4. **The transcript types itself in at the cursor** when you release. In English
   mode, Parrot decodes confirmed segments privately while you are still
   speaking, then reconciles only the unfinished tail on release. Automatic and
   German modes still transcribe the completed recording because routing or the
   German specialist requires the finished audio. Parrot recognizes native,
   web, and Electron text editors through writable attributes and semantic text
   roles. If no text editor is focused, it copies the transcript and shows a brief
   **Copied to clipboard** pill instead of sending keystrokes to the wrong place.

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
Automatic first uses the stronger 488 MB multilingual Whisper Small model to detect the
language. Confident English is then transcribed with the English-specific
Whisper Large v3 Turbo model; confident German is transcribed with the German-specific
Whisper Large v3 Turbo Q5 model. Other or ambiguous languages fall back to the
multilingual model. The English (~1.62 GB) and German (~548 MB) specialists are
prefetched in the background on first app launch and cached locally. Audio
remains on the Mac; only model downloads use the network.

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
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --no-overlay                    # disable the bottom-of-screen pill
```

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
