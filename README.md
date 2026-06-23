# breath-synth

A native macOS Swift breathing synthesizer. It renders exact-duration inhale and
exhale cues from 1 to 30 seconds.

The default engine is now fully procedural: no assets, no ElevenLabs key, and no
manifest are required. The older sampled-asset path is still available for
recorded or licensed breath palettes.

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

Render a procedural breath to a WAV file:

```sh
swift run breath render --generator tract --type inhale --duration 12 --style calm --out /tmp/inhale12.wav
```

Play a single procedural breath:

```sh
swift run breath play --generator klatt --type exhale --duration 6 --style calm
```

Play a breathing cycle:

```sh
swift run breath cycle --generator granular --inhale 4 --hold-in 1 --exhale 6 --hold-out 1 --style calm --loop
```

Press Ctrl-C to stop a looping cycle.

Render the three-candidate procedural shootout:

```sh
swift run breath shootout --out /tmp/breath-shootout
```

That writes:

- `A_tract_*`: 1D vocal-tract tube / waveguide model with turbulent airflow.
- `B_klatt_*`: Klatt-style aspiration and frication through formant filters.
- `C_granular_*`: stochastic micro-burst turbulence with moving airway detail.

## CLI reference

The playback and rendering commands use `--source procedural` by default.

| Command | What it does |
| --- | --- |
| `render --generator tract --type inhale --duration 12 --style calm --out out.wav` | Render a procedural breath to WAV. |
| `play --generator klatt --type exhale --duration 6 --style calm` | Render and play one procedural breath. |
| `cycle --generator granular --inhale 4 --hold-in 1 --exhale 6 --hold-out 1 --style calm --loop` | Play a repeating procedural cycle. |
| `shootout --out /tmp/breath-shootout` | Render A/B/C procedural candidates for listening judgment. |
| `generate-assets [--styles a,b] [--output-format pcm_44100] [--force]` | Generate an optional sampled palette via ElevenLabs. |
| `dev-stub-assets [--styles a,b]` | Generate optional placeholder sampled assets for asset-mode testing. |

Supported procedural styles are `calm` and `neutral`. Supported procedural
generators are `tract`, `klatt`, `granular`, and `legacy`.

## Optional sampled mode

Sampled mode is still useful for recorded breaths, licensed assets, or
ElevenLabs-generated source material.

Generate placeholder sampled assets:

```sh
swift run breath dev-stub-assets --styles neutral,calm
swift run breath render --source assets --assets Assets/breaths --type inhale --duration 8 --style calm --out /tmp/asset-inhale8.wav
```

Generate ElevenLabs sampled assets:

```sh
export ELEVENLABS_API_KEY=sk_...
swift run breath generate-assets --styles neutral,calm
swift run breath cycle --source assets --assets Assets/breaths --inhale 4 --hold-in 1 --exhale 6 --hold-out 1 --style calm
```

If your ElevenLabs plan rejects `pcm_44100`, pass a lower rate:

```sh
swift run breath generate-assets --styles neutral --output-format pcm_24000
```

Assets are resampled to the engine's 44.1 kHz working format on load.

## How it works

Procedural mode now has multiple generator families. `tract` is the default and
models a simple 1D vocal tract with turbulent airflow. `klatt` is a source-filter
baseline with aspiration/frication noise and oral/nasal formants. `granular`
uses stochastic airflow micro-bursts for less periodic texture. `legacy` is the
older filtered-noise renderer, kept only as a comparison point.

Sampled mode uses the existing attack, sustain, release assembler:

```text
generateBreath(type, duration):
  duration < 1.5s: resample a one-shot / loop window to the exact length
  otherwise: start clip + loopable sustain + end clip
  joins: equal-power crossfades
  contour: natural amplitude envelope with zero endpoints
```

Both modes render mono Float32 audio at 44.1 kHz and play through
`AVAudioEngine`.

## Architecture

- `Sources/BreathEngine/DSP/`: pure math and procedural audio generation.
- `Sources/BreathEngine/Assembly/`: sampled asset assembly and asset loading.
- `Sources/BreathEngine/Playback/`: AVFoundation playback.
- `Sources/BreathCLI/`: CLI harness and optional ElevenLabs asset generation.
