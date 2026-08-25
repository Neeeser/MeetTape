# Contributing to Pipit

Pipit is a Swift package that builds a macOS menu-bar application and a browser
sensor. Contributions should keep capture reliable, meeting content private,
and stored recordings readable across versions.

## Requirements

- macOS 15 or later
- Swift 6
- Xcode or Apple Command Line Tools
- Node.js 22 for browser sensor changes

Xcode is optional. The repository scripts support a Command Line Tools-only
environment.

## Build and test

Clone the repository and run the application tests:

```sh
git clone https://github.com/Neeeser/Pipit.git
cd Pipit
./scripts/build.sh debug
./scripts/test.sh
```

Build an application bundle with:

```sh
./scripts/bundle-app.sh debug
open dist/Pipit.app
```

Use the scripts instead of bare SwiftPM commands. They configure the SDK and
repair known Command Line Tools problems before Swift runs. The test suite uses
the `pipit-test` executable, so `swift test` is not supported.

## Targeted checks

List or filter application tests with:

```sh
./scripts/test.sh --list
./scripts/test.sh --filter CaptureRecovery
```

Run the browser sensor tests after changing `extension/`:

```sh
cd extension
npm test
npm run build
```

Run the full application and extension tests before opening a pull request:

```sh
./scripts/test.sh
(cd extension && npm test)
```

Run `./scripts/check-offline.sh` after changing model installation or code that
constructs `PipitRuntime`, `SetupModel`, or `LocalModelManager`. It fails if an
ordinary test starts a model download.

## Project structure

`PipitCore` contains deterministic logic. The audio, detection, integration,
local AI, speaker, service, and UI modules own their corresponding I/O and state.
See [the architecture guide](docs/ARCHITECTURE.md) for module boundaries and
data flow.

The browser sensor lives in `extension/`. The `pipit-nativehost` executable
relays its events to Pipit.

## Pull requests

Keep each pull request focused on one change. Add a regression test for every
bug fix and confirm that the test fails before the fix and passes after it.
Test behavior at the lowest layer that exposes the defect.

Do not commit recordings, API keys, benchmark audio, or meeting content. The
CI hygiene job rejects audio files and strings shaped like API keys.

Ad-hoc application builds receive new macOS permission grants after each
rebuild. A Developer ID build keeps a stable signing identity.

## Benchmarks and releases

Changes to speech models, diarization, alignment, or transcript assembly may
require the benchmark gate. See [Benchmarks](Benchmarks/README.md).

Maintainers can find the release procedure in
[docs/RELEASING.md](docs/RELEASING.md).

## License

Contributions are licensed under the [MIT License](LICENSE).
