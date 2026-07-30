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
Microphone consent and launches the new app. Re-enable the permissions when
macOS prompts. Enable **Launch Parrot at login** from the menu-bar popover.

## Command-line install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

## How to use

1. **Run it.** Open `Parrot.app`, or run `parrot` in a terminal.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot. Click the Parrot menu-bar icon to record a different shortcut or switch to **Toggle** (press once to start, once again to stop).
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button or "send" button—the configured global shortcut is the recording control.

The **Language** setting supports English, German, or Automatic recognition.
German and Automatic use the 147 MB multilingual Whisper Base model, which
downloads to WhisperKit's local cache on first use. Audio remains on the Mac.
Whisper Large v3 Turbo remains available through the CLI when maximum accuracy
is worth a much larger model and slower startup.

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
