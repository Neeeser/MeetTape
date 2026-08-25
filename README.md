![Pipit meeting recorder](Assets/Pipit/README/pipit-readme-hero.png)

# Pipit

[![CI](https://github.com/Neeeser/Pipit/actions/workflows/ci.yml/badge.svg)](https://github.com/Neeeser/Pipit/actions/workflows/ci.yml)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Pipit is an open-source meeting recorder for macOS. It detects Slack Huddles
and calls in supported browsers, records your microphone and meeting audio
separately, then creates an editable transcript with speaker labels.

Transcription and speaker recognition run on your Mac by default. Pipit stores
recordings, transcripts, and notes as ordinary files on disk.

## Install

Pipit requires macOS 15 or later.

Download the latest disk image from [GitHub Releases](https://github.com/Neeeser/Pipit/releases/latest),
or install it with Homebrew:

```sh
brew install --cask pipit
```

Open Pipit and grant the permissions shown during setup. Pipit then runs from
the menu bar.

## Features

- Detects Slack Huddles, Google Meet, and Zoom calls
- Records the microphone and meeting application as separate audio tracks
- Transcribes locally with Apple SpeechAnalyzer or Parakeet
- Separates speakers and recognizes voices across meetings
- Imports WAV, M4A, MP3, CAF, AIFF, and MP4 recordings
- Saves editable transcripts, summaries, notes, and source audio to disk

## How it works

```text
detect the call -> record separate tracks -> transcribe and identify speakers -> save the meeting
```

Pipit keeps a short audio pre-roll while a call is being confirmed, so the
recording includes its opening. Processing starts after capture is safe on disk.
OpenAI transcription and enrichment are optional settings.

## Privacy

Local transcription, speaker separation, and voice recognition keep meeting
audio on your Mac. Pipit uploads audio only when you select a cloud speech
model. Optional titles, summaries, and notes send transcript text to the model
you configure.

Pipit has no account, telemetry, analytics, or hosted meeting database. Voice
profiles stay under Application Support and are excluded from meeting folders
and exports.

## Documentation

- [Contributing](CONTRIBUTING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Benchmarks](Benchmarks/README.md)
- [Verification](docs/VERIFICATION.md)
- [Releasing](docs/RELEASING.md)

## License

Pipit is available under the [MIT License](LICENSE).
