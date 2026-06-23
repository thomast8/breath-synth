# breath-synth

A native macOS Swift breathing synthesizer. It renders exact-duration inhale and
exhale cues from 1 to 30 seconds.

The engine has a single render path: it is asset-driven. Each render takes a full
recorded breath (one `oneShot` clip per style and type) and reshapes it to the
requested duration using the `recordedShape` assembler. A built-in `calm` palette
ships in `Assets/breaths`, so no setup is required to run the examples below.

## Requirements

- macOS 13+
- Swift 6.3 toolchain
- Xcode if you want to run the XCTest suite on macOS

## Build and test

```sh
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The `DEVELOPER_DIR` prefix is only needed when `xcode-select` points at Command
Line Tools, since Apple's CLT install does not include XCTest.

## Quick start

Render a breath to a WAV file:

```sh
swift run breath render --type inhale --duration 12 --style calm --out /tmp/inhale12.wav
```

Play a single breath:

```sh
swift run breath play --type exhale --duration 6 --style calm
```

Play a breathing cycle:

```sh
swift run breath cycle --inhale 4 --hold-in 1 --exhale 6 --hold-out 1 --style calm --loop
```

Press Ctrl-C to stop a looping cycle.

All commands read the breath palette from `--assets Assets/breaths` by default.

## CLI reference

| Command | What it does |
| --- | --- |
| `render --type inhale --duration 12 --style calm --out out.wav` | Render a breath to WAV. |
| `play --type exhale --duration 6 --style calm` | Render and play one breath. |
| `cycle --inhale 4 --hold-in 1 --exhale 6 --hold-out 1 --style calm --loop` | Play a repeating cycle. |

Common options:

- `--assets <dir>`: directory containing the breath assets and `manifest.json` (default `Assets/breaths`).
- `--style <name>`: breath style; the bundled palette provides `calm`.
- `--seed <n>` / `--no-variation` (`play` and `render` only): control the subtle per-render variation.

## How it works

The engine renders mono Float32 audio at 44.1 kHz. For each breath it loads the
`oneShot` recording for the requested style and type, then the `recordedShape`
assembler:

```text
generateBreath(type, duration):
  trim outer silence and low-cut the recorded source (removes room rumble)
  measure the recording's RMS energy envelope
  reshape that envelope to the requested duration with smooth attack/release
  re-render the breath texture to follow the reshaped envelope
  low-cut the delivered audio again and zero the endpoints
```

Rendered breaths play through `AVAudioEngine`.

## Architecture

- `Sources/BreathEngine/DSP/`: pure DSP primitives (filters, crossfades, resampling, envelopes).
- `Sources/BreathEngine/Assembly/`: asset loading and the `recordedShape` assembler.
- `Sources/BreathEngine/Playback/`: AVFoundation playback.
- `Sources/BreathCLI/`: CLI harness.
- `Assets/breaths/`: the bundled `calm` palette and its `manifest.json`.
