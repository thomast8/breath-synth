# breath-synth

A native macOS/iOS Swift breathing synthesizer. Renders exact-duration inhale/exhale cues (1–30 s)
from recorded breath palettes, plus breathing cycles and timed sequences. North-star use case is a
static-apnea / freediving trainer (FRC/RV exhales, packing, recovery breaths), so the engine is a pure
timing/DSP primitive and technique/mode catalogs live in the CLI/app layer.

## Build / test / run

```sh
swift build                        # or: make build  →  dist/breath, dist/breath-debug
swift test                         # needs the Xcode toolchain (swift-testing's runtime isn't wired up
                                   # under bare CommandLineTools); if `xcode-select -p` points at CLT,
                                   # prefix: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
swift run breath <subcommand> ...  # CLI: render | play | cycle | sequence
swift run breath-debug             # SwiftUI debug app (reads ./Assets/breaths)
bash scripts/make-debug-app.sh     # → dist/BreathDebug.app (visible in Finder; bundles palette, ad-hoc signed)
```

Platform is **macOS/iOS 26** (so `@Observable`, modern Accelerate, etc. are available). Working sample
rate is **44.1 kHz** (`AudioConstants.workingSampleRate`); all assets are resampled to it on load.

## Targets

- **BreathEngine** (library) — the synth. Top-level API in `Sources/BreathEngine/BreathEngine.swift`.
- **BreathCLI** (`breath`) — `Sources/BreathCLI/`. Subcommands: render / play / cycle / sequence.
- **BreathDebugApp** (`breath-debug`) — `Sources/BreathDebugApp/`. SwiftUI app to exercise everything.

## North star: fixes belong in the engine

Bugs and behavior gaps found while exercising `BreathCLI`, `BreathDebugApp`, or `BreathEnrollApp` get
fixed in `BreathEngine` (or `BreathBank` for enrollment/grading) — never patched around in app code. The
apps are thin consumers (capture, playback, visualization) with no DSP/timing/decision logic of their
own; a fix that lives only in one app leaves the same defect in every other consumer. Diagnose from the
app, fix in the library, verify against the library's test suite.

## Engine layout (`Sources/BreathEngine/`)

- `Model/` — `BreathTypes` (BreathType, BreathSpec, CycleSpec, VariationOptions, BreathError),
  `Manifest` (BreathManifest, StyleManifest, RolePalette, **RenderMode**), `SequenceTypes`
  (BreathPattern, SequencePlan, BreathFormat).
- `DSP/` — Biquad, Crossfade, Envelope, Resample, Segments, SpectralDenoise, UnitExtractor,
  Variation (`SeededRNG` splitmix64).
- `Assembly/` — **BreathAssembler** (the core render math), AssetLibrary (decode + cache, path-safe).
- `Sequence/` — SequencePlanner (fit a BreathPattern into a target total; strict vs `.closest`).
- `Playback/` — BreathPlayer (AVAudioEngine + AVAudioPlayerNode, main-actor).

## How a render works (the important part)

Each style declares a **RenderMode** in `manifest.json` (`"render"`, default `textured`). `BreathAssembler`
and `BreathEngine.renderSamples`/`renderCountedSamples` branch on it:

- **textured** (calm, full, hyperventilation) — `recordedShapeBranch`: extract the loud, steady sustain
  texture from the recording, loop it to the *exact* requested duration (grain crossfades to avoid a
  periodic wobble), then impose a designed `Envelope.curve`. Duration is honored.
- **oneShot** (frc, rv) — `oneShotBranch`: return the recording at its **natural length** (duration is
  ignored). `trimToMainBody` crops the head to the breath onset and keeps the natural decay tail; a
  short settle pause is appended. *`trimToMainBody` is only called here — never on the textured path.*
- **counted** (recovery, packing) — `renderCountedSamples`: lay down N discrete events. One take →
  `UnitExtractor.extract` + `assembleCounted` (a verbatim contiguous slice of the recording). Two takes
  → `gulpCores` + `rhythmGaps` + `assembleHybrid` (clean cores at another take's rhythm; used by
  packing). Counted styles **throw `styleRequiresCount`** from duration-based render/cycle/sequence.
  A one-take `count: 1` render with a `seed` plays unit `seed % units` (unseeded: unit 0).
- **recovery breath** (`renderRecoveryBreathSamples(index:cadence:seed:)`) — one hook breath laid out on a
  `RecoveryCadence` (`.standard` = inhale 1.0 / hook 1.0 / exhale 1.5 / pause 0.5 s; loudness hook peak 0.6, tail 0.85×, release 1.3×, tuned by ear in BreathDebug), exactly
  `round(breathSec × rate)` frames: a 1 s `hyperventilation` textured inhale, silence for the hook, the
  recorded out-release of hook `index % 6` (`UnitExtractor.hookParts`) crossfaded into the tail of a calm
  textured exhale (`BreathAssembler.assembleRecoveryBreath`), silence for the pause. A caller that draws a
  guide from the same cadence is in step with the audio by construction. `renderRecoveryReleaseSamples`
  is the audible post-hold release (calm exhale, `cadence.release`, default 2.5 s).

Renders are **deterministic**: `seed` → `SeededRNG`; when nil a stable seed is derived from the spec
(`Variation.stableSeed`), and `render(spec)` is cached by a canonical key. Denoise is **on by default**
(room-tone profile `room_silence.aifc`; `AssemblerSettings.enableSpectralDenoise`).

## Styles (`Assets/breaths/manifest.json`)

| style | mode | directions | notes |
| --- | --- | --- | --- |
| calm | textured | inhale, exhale | default, relaxed |
| full | textured | inhale | full-lung inhale |
| frc | oneShot | exhale | passive exhale to FRC |
| rv | oneShot | exhale | forced exhale to RV |
| recovery | counted | inhale | post-hold hook breaths: 6 hooks, each an in-sip then an out-release ~0.5 s later. Nadir plays them through `renderRecoveryBreathSamples` (cadence above), which uses only the out-releases |
| packing | counted | inhale | glossopharyngeal packing (hybrid, 2 takes) |
| hyperventilation | textured | inhale, exhale | fast/forceful |

Assets are committed AIFC (48 kHz mono); the manifest records each file's durationSec/sampleRate/channels.
`BreathEngine.styleNames()` / `renderMode(for:)` / `supportedDirections(for:)` are what the UI uses to
gate its pickers.

## Public render/playback API (`BreathEngine`)

`renderSamples`/`render` (single), `renderCycle`, `renderSequence(plan)`, `renderCounted(style:type:count:seed:)`,
`renderRecoveryBreathSamples(index:cadence:seed:)` / `renderRecoveryReleaseSamples(cadence:seed:)` (each with an
`…OffActor` variant);
`*ToWAV` variants; `play`/`playCycle`/`playSequence`/`playCounted`; `play(_ buffer)` and
`play(_ buffer, fromFrame:)` (seek); `pause`/`resume`; `currentSampleTime` (playhead); `stop`.

## Debug app (`Sources/BreathDebugApp/`)

`DebugModel` (`@MainActor @Observable`) drives a `BreathEngine`. Four task tabs (single / counted /
cycle / sequence) gated by each style's render mode. Right pane: waveform (with phase/cycle boundary
guides), **spectrogram** (Accelerate/vDSP STFT, heat-mapped, `Spectrogram.swift`) + spectral-flux
**transient onset markers** (good for spotting clicks/glottal stops), a **time axis**, and a **playhead**
you can drag to seek; Pause/Play/Stop/Save-WAV. Every action is fanned out to a loopback **SSE** stream
(`curl -N http://127.0.0.1:$BREATH_DEBUG_PORT/`, default 8789) and a **JSONL** file
(`$BREATH_DEBUG_LOG`, default `~/Library/Logs/BreathDebug/session.jsonl`) via `SessionLogger` /
`DebugStreamServer`. The bundled `.app` ships the palette in `Resources/breaths` and resolves it via
`Bundle.main`; `swift run` resolves `./Assets/breaths`.

## Gotchas

- `swift test` needs Xcode (see above). Tests use swift-testing (`import Testing`, `@Test`, `#expect`/
  `#require`) under `Tests/BreathEngineTests/` and `Tests/BreathBankTests/`.
- Editing a recording in `Assets/breaths/` changes the render verbatim for counted/oneShot styles
  (no synthesis hides it). Update the manifest's `durationSec` if length changes; keep a backup.
- `recovery` through `renderCounted` is a verbatim slice — its "glottal stop" artifacts are in the
  recording, not a join bug (adjacent extracted units are contiguous; there is no concatenation step).
  Played as recorded a hook is ~1 s, too fast to follow; use the recovery-breath API for paced breaths.
- The `full` style has no exhale recordings: a `full` exhale render is silence. The recovery release is
  rendered from `calm` for that reason.
