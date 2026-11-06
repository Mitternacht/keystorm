# Keystorm

Local AI dictation for macOS. Press a shortcut, speak, and your words appear in the app you are using. Speech recognition and text cleanup run on your Mac.

Website: https://mitternacht.github.io/keystorm/

Keystorm is in development. There is no signed or notarized download yet; you can build it from source.

## What it does

- Press <kbd>⌥⇧⌘D</kbd> in a text field, speak, and press it again. The text goes into the field you started in. <kbd>⌥⇧⌘P</kbd> pauses and resumes. You can change both shortcuts in Settings.
- The on-device speech model recognizes 25 European languages and writes down what you said in the language you said it.
- Verbatim mode (the default) inserts the transcript as recognized. Clean fixes punctuation, capitals and a few filler sounds. Email does the same and adds paragraphs. Translate makes a preview you can apply afterwards. The Clean, Email and Translate instructions are written for English and German, and Translate writes English or German.
- If you turn learning on, Keystorm suggests remembering the names and terms you correct. Nothing is reused until you approve it, and learned words are applied in English and German text.
- For long recordings, audio is saved as you speak and survives a restart. You can pause and resume, save a trimmed copy, replace a take with an audio file, and keep summaries as separate versions. The original is never overwritten.

## Where your text goes

| Destination | What happens |
| --- | --- |
| TextEdit | Inserted and confirmed |
| Other apps | Pasted after the text field is checked |
| Terminals | Copied to the clipboard |
| Password managers and password fields | Never |

Outside TextEdit, pasting has been tested in Stickies and Dictionary so far; browsers and Electron apps are not verified yet. Keystorm restores your clipboard after a paste when it can, never presses Return, and puts the result on the clipboard if it could not be inserted, for example because the destination changed while you were talking (Settings → Dictation → Copy when not inserted). You can block any app or website in Settings.

## Privacy

The speech model and the text model run locally on your Mac. There is no account, no cloud service and no analytics. Keystorm goes online only when you choose to download a model from Hugging Face, and every file is checked against a checksum pinned in the app. Recordings, transcripts and learned words are stored in `~/Library/Application Support/Keystorm`. The [privacy page](https://mitternacht.github.io/keystorm/privacy.html) has the details.

## Requirements

- macOS 27 on a Mac with Apple silicon
- 0.6 GB for the speech model (Parakeet Ultra, Core ML), plus 3.1 GB for the optional text model (Qwen3.5-4B, 4-bit, MLX) used by Clean, Email, Translate and summaries

## Build from source

1. Open `Keystorm.xcodeproj` in Xcode 27.
2. Select the **Keystorm** scheme and **My Mac**.
3. Under Signing & Capabilities, choose your own development team.
4. Build and run. On first launch, **Set Up Keystorm** walks you through microphone access, Accessibility access and the model downloads (also available later under Settings → Local models).

<kbd>⌘U</kbd> runs the unit tests in `KeystormTests` and the UI tests in `KeystormUITests`; the UI tests open Keystorm windows on your desktop. Tests that need the installed models, a microphone or other apps are opt-in and skip by default.

## Repository

- `Keystorm/`: the app (Swift, SwiftUI)
- `KeystormTests/`, `KeystormUITests/`: unit and UI tests
- `Release/`: release checks (`preflight.py`, `audit_signatures.py`, `soak.py`)
- `website/`: the project website, published with GitHub Pages
- `Keystorm/ThirdPartyNotices.txt`: licenses for bundled libraries and data

## Contributing

Issues and pull requests are welcome. Pull requests are reviewed before they are merged.

## License

No license has been chosen yet, so all rights are reserved for now.
