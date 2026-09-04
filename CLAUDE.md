# Pipit development notes

Pipit is a Swift 6 macOS menu-bar application that records meetings and stores
the results as files on disk.

## Commands

Use the repository scripts. They configure the SDK and repair known Command
Line Tools problems. `swift test` is not supported. `spm-env.sh` is Bash-only
and must not be sourced from zsh.

```sh
./scripts/build.sh debug
./scripts/test.sh
./scripts/test.sh --filter Name
./scripts/bundle-app.sh debug
```

Run the browser sensor checks after changing `extension/`:

```sh
(cd extension && npm test && npm run build)
```

Before finishing a change, run `./scripts/test.sh` and
`(cd extension && npm test)`.

Run `./scripts/check-offline.sh` after changing model installation or code that
constructs `PipitRuntime`, `SetupModel`, or `LocalModelManager`.

## Modules

| Module | Responsibility |
| --- | --- |
| `PipitCore` | Pure models, policy, storage layout, and transcript assembly |
| `PipitAudio` | Capture, process taps, audio files, import, and mixdown |
| `PipitDetection` | Accessibility, window, process, and browser evidence |
| `PipitIntegrations` | OpenAI, Keychain, EventKit, notifications, and permissions |
| `PipitLocalAI` | On-device speech models and model installation |
| `PipitSpeakers` | Voice profiles and speaker resolution |
| `PipitServices` | Runtime wiring, meeting storage, and processing pipeline |
| `PipitUI` | Menu bar, setup, settings, meetings window, and people |

`PipitServices` also holds `EchoMeasurement`, which nothing in the application
calls. It measures what `MicrophoneCleaner` does to a recording and is run from
`pipit-eval echo`. It ships in the app binary rather than living in the tool
because the test target cannot link an executable target, and because it shares
`EchoCancellationPass` with the cleaner so that a measurement describes the pass
that ships rather than a second copy of it.

## Project constraints

- Treat source audio, manifests, raw model output, and imported originals as
  immutable after they are written.
- Keep meeting content out of logs. Log identifiers, counts, durations, states,
  and typed error categories.
- Store API keys in Keychain. Never commit keys, recordings, or benchmark audio.
- Keep voice profiles under Application Support and out of meeting folders.
- Speech dependencies are pinned to measured versions. A version change requires
  benchmark evaluation.
- An imported recording is dated from what the recorder wrote: the container's
  creation date, then a timestamp in the filename, then the file's date on this
  Mac. The manifest still owns how long the audio runs.

## References

- [Contributing](CONTRIBUTING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Benchmarks](Benchmarks/README.md)
- [Verification](docs/VERIFICATION.md)
- [Releasing](docs/RELEASING.md)
