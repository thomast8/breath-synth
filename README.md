# breath-synth

A native macOS Swift breathing synthesizer. It renders exact-duration inhale and
exhale cues from 1 to 30 seconds.

The engine has a single render path: it is asset-driven. Each render takes a full
recorded breath (one `oneShot` clip per style and type) and reshapes it to the
requested duration using the `recordedShape` assembler. A set of recorded palettes
ships in `Assets/breaths` (see [Breath styles](#breath-styles)), so no setup is
required to run the examples below.

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

Fill a target duration with a whole number of cycles:

```sh
swift run breath sequence --total 30 --inhale 5 --exhale 5            # 3 cycles = 30s, plays
swift run breath sequence --total 30 --inhale 3 --exhale 6            # error: 9s cycle doesn't tile 30s; proposes 27s / 36s
swift run breath sequence --total 30 --inhale 3 --exhale 6 --closest  # renders the nearest fit (27s)
swift run breath sequence --total 30 --inhale 3 --exhale 6 --closest --out /tmp/seq.wav
```

Breath durations are kept exact, so the total flexes to the nearest whole-cycle
length. By default a pattern that doesn't tile `--total` evenly fails and proposes
the nearest totals; `--closest` renders the nearest one instead. Each cycle is
re-seeded so the run doesn't sound like one identical loop repeated. Omit `--out`
to play (add `--loop` to repeat the whole sequence).

All commands read the breath palette from `--assets Assets/breaths` by default.

## Breath styles

The bundled palette (`Assets/breaths/manifest.json`) provides these styles. Each
recording is a steady single-direction airflow; the engine extracts its texture and
imposes the inhale/exhale shape with its designed envelope.

| Style | Direction(s) | Intended use |
| --- | --- | --- |
| `calm` | inhale, exhale | relaxed breathe-up (default) |
| `full` | inhale | full-lung inhale |
| `frc` | exhale | passive exhale to functional residual capacity |
| `rv` | exhale | forced exhale to residual volume |
| `recovery` | inhale | post-hold recovery / hook breaths |
| `hyperventilation` | inhale, exhale | fast, forceful, turbulent breathing |

Each style only carries the direction(s) it is meant for; requesting the other
direction raises an error. A `packing` (glossopharyngeal insufflation) recording
ships in `Assets/breaths` but is not yet wired into the manifest: its staccato
gulp-train would be smeared by the current flatten-and-loop path, so it awaits a
structure-preserving generator.

## CLI reference

| Command | What it does |
| --- | --- |
| `render --type inhale --duration 12 --style calm --out out.wav` | Render a breath to WAV. |
| `play --type exhale --duration 6 --style calm` | Render and play one breath. |
| `cycle --inhale 4 --hold-in 1 --exhale 6 --hold-out 1 --style calm --loop` | Play a repeating cycle. |
| `sequence --total 30 --inhale 5 --exhale 5 [--closest] [--out out.wav]` | Fill a total duration with whole cycles (exact durations, nearest total). |

Common options:

- `--assets <dir>`: directory containing the breath assets and `manifest.json` (default `Assets/breaths`).
- `--style <name>`: breath style; the bundled palette provides `calm`, `full`, `frc`, `rv`, `recovery`, and `hyperventilation` (see [Breath styles](#breath-styles)).
- `--seed <n>` (`play`, `render`, `sequence`) / `--no-variation` (`play` and `render` only): control the subtle per-render variation. For `sequence`, `--seed` pins the whole run.
- `--denoise` / `--no-denoise` (default off): optional FFT noise-profile subtraction on the recorded source to suppress steady hiss. Tune with `--denoise-oversub` / `--denoise-floor`. Off by default (modest benefit on the current pipeline).

## How it works

The engine renders mono Float32 audio at 44.1 kHz. For each breath it loads the
`oneShot` recording for the requested style and type, then the `recordedShape`
assembler:

```text
generateBreath(type, duration):
  trim outer silence and low-cut the recorded source (removes room rumble)
  optionally spectral-subtract the steady noise floor (--denoise; off by default)
  measure the recording's RMS energy envelope
  reshape that envelope to the requested duration with smooth attack/release
  re-render the breath texture to follow the reshaped envelope
  low-cut the delivered audio again and zero the endpoints
```

Rendered breaths play through `AVAudioEngine`.

## Architecture

- `Sources/BreathEngine/DSP/`: pure DSP primitives (filters, crossfades, resampling, envelopes).
- `Sources/BreathEngine/Assembly/`: asset loading and the `recordedShape` assembler.
- `Sources/BreathEngine/Sequence/`: fits a breath pattern into a target duration (`SequencePlanner`).
- `Sources/BreathEngine/Playback/`: AVFoundation playback.
- `Sources/BreathCLI/`: CLI harness.
- `Assets/breaths/`: the bundled breath palettes and their `manifest.json`.
