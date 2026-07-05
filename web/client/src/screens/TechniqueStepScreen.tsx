import { useEffect, useRef, useState } from "react";
import { LevelMeter } from "../components/LevelMeter";
import { WaveformView } from "../components/WaveformView";
import type { DetectionState, StepSnapshot, TakeRetake, TakeRetakeIssue, TakeVerdict } from "../ws/protocol";
import type { WavePeak } from "../audio/StreamingCapture";

const REASON_TEXT: Record<string, string> = {
  clipped: "that one clipped — try a bit farther from the mic",
  length: "that one was the wrong length",
  dropout: "that one had a mid-breath dropout",
  low_snr: "that one was too quiet against the room",
  merged_gulp: "some events ran together — try leaving clearer gaps",
  unreadable: "the recording couldn't be read — please try again",
};

function friendlyReason(reason: string | null): string {
  if (!reason) return "that take didn't pass the quality check";
  return REASON_TEXT[reason] ?? `that take didn't pass the quality check (${reason})`;
}

// Mirrors native `retakeReason(_:)` — the structural validity guard's rejection reasons, distinct
// from `REASON_TEXT` above (the async grader's reasons for a take that was actually written).
const STRUCTURAL_TEXT: Record<TakeRetakeIssue, string> = {
  no_pause: "couldn't find the pause between inhale and exhale — pause a beat longer",
  inhale_too_short: "the inhale was too short",
  exhale_too_short: "the exhale was too short",
  phases_imbalanced: "the two phases were too uneven in length",
  no_segment: "no breath was detected",
  no_pause_before_release: "never reached the pause before releasing",
};

function friendlyStructuralReason(retake: TakeRetake): string {
  const base = STRUCTURAL_TEXT[retake.issue] ?? "that one didn't pass the structural check";
  return retake.issue === "phases_imbalanced" && retake.ratio != null
    ? `${base} (${retake.ratio.toFixed(1)}x)`
    : base;
}

const EVENT_COUNTED = new Set<StepSnapshot["detection"]>(["cleanEvents", "naturalRhythm"]);

// Mirrors native `phaseLabel(_:)` (`EnrollContentView.swift`) — the rich, per-livePhase status text.
function phaseLabel(step: StepSnapshot, detection: DetectionState | null): string {
  if (!detection) return "";
  const elapsed = detection.phaseElapsed.toFixed(1);
  switch (detection.livePhase) {
    case "waiting":
      if (detection.blackoutRemaining > 0) {
        return `Settling & calibrating… ${detection.blackoutRemaining.toFixed(1)}s before it starts listening`;
      }
      return step.detection === "cycle" || step.isPairedRecovery
        ? "Ready — inhale when you are"
        : "Ready — begin when you are";
    case "inhale":
      return EVENT_COUNTED.has(step.detection) ? "Inhale…" : `Inhaling… ${elapsed}s`;
    case "midPause":
      return "Pause — now exhale";
    case "exhale":
      return EVENT_COUNTED.has(step.detection) ? "Exhale…" : `Exhaling… ${elapsed}s`;
    case "capturing":
      return `Capturing… ${elapsed}s`;
    default:
      return "";
  }
}

// Mirrors native `phaseFloorHint(_:)` (`EnrollContentView.swift`) exactly: a per-phase floor readout
// for `cycle`'s inhale/exhale and `finalPhase`'s kept exhale, PLUS a whole-take length-floor variant
// for `naturalRhythm` (packing/recovery-cadence) — it has no fixed event target ("continuous cadence,
// not discrete events"), so the length band is the only "are we there yet" signal worth showing.
// `cleanEvents` has neither — its own event counter (`eventCounterText`) is the guidance there.
function phaseFloorHint(step: StepSnapshot, detection: DetectionState | null): string | null {
  if (!detection) return null;
  const phase = detection.livePhase;
  const appliesToPhaseSplit =
    (step.detection === "cycle" && (phase === "inhale" || phase === "exhale")) ||
    (step.detection === "finalPhase" && phase === "exhale");
  const appliesToNaturalRhythm =
    step.detection === "naturalRhythm" && (phase === "capturing" || phase === "inhale" || phase === "exhale");
  if (!appliesToPhaseSplit && !appliesToNaturalRhythm) return null;

  const min = step.minSeconds.toFixed(1);
  const met = detection.phaseElapsed >= step.minSeconds;
  if (!met) return `${detection.phaseElapsed.toFixed(1)}s so far — needs ≥${min}s`;
  return appliesToNaturalRhythm ? `✓ long enough (≥${min}s) — wrap up whenever` : `✓ long enough (≥${min}s)`;
}

// Mirrors native's event-counter block (`"{count} / ~{target} detected"`, shown for both `cleanEvents`
// and `naturalRhythm` regardless of whether a target exists — `naturalRhythm` always has `targetEvents:
// nil`, so it reads as a bare count with `phaseFloorHint`'s length band as its "are we done" signal).
function eventCounterText(step: StepSnapshot, detection: DetectionState | null): string | null {
  if (!EVENT_COUNTED.has(step.detection)) return null;
  const count = detection?.eventCount ?? 0;
  const target = step.targetEvents != null ? ` / ~${step.targetEvents}` : "";
  return `${count}${target} detected`;
}

function eventTargetReachedText(step: StepSnapshot, detection: DetectionState | null): string | null {
  if (step.targetEvents == null) return null;
  const count = detection?.eventCount ?? 0;
  return count >= step.targetEvents ? `Got all ${step.targetEvents} — wrapping up` : null;
}

// Duration-bound kinds (`cycle`/`finalPhase`/`single`) have no event counter at all — this is a
// deliberate addition beyond native, surfacing the bounds `StepSnapshot` already sends once per step
// but the client never displayed live, closing the "each take has different numbers of data points,
// everything has to be aligned" gap.
function durationGuidance(step: StepSnapshot): string | null {
  if (EVENT_COUNTED.has(step.detection)) return null;
  return `Aim for ${step.minSeconds.toFixed(1)}–${step.maxSeconds.toFixed(1)}s`;
}

// Native's meter scales to the activity threshold, not a flat cosmetic denominator, so the bar reads
// in the same units the engine is actually gating on (`meterFraction = level / (max(threshold,
// 0.004) * 2.5)`, `EnrollContentView.swift`).
function meterThreshold(detection: DetectionState | null): number | undefined {
  if (!detection) return undefined;
  return Math.max(detection.activityThreshold, 0.004) * 2.5;
}

interface Props {
  step: StepSnapshot;
  stepNumber: number;
  totalSteps: number;
  armed: boolean;
  detection: DetectionState | null;
  ambientHold: boolean;
  lastVerdict: TakeVerdict | null;
  lastRetake: TakeRetake | null;
  stepNotice: string | null;
  roomToneReady: boolean;
  clientLevel: { rms: number; peak: number };
  waveformPeaks: WavePeak[];
  onStartStep: () => void;
  onStopTake: () => void;
  onRedoTake: () => void;
  onOverrideAmbientGate: () => void;
  onSkipStep: () => void;
  onRequestStartOver: () => void;
}

/** Fully server-driven — no manual record button. "Start step" arms the ported
 * `TakeCaptureEngine` on the server; takes self-terminate and auto-advance across the whole step
 * exactly as the native app, including automatic redo (a rejected take re-arms the same take index
 * without the participant doing anything). `onStopTake`/`onRedoTake` are visible escape hatches only. */
export function TechniqueStepScreen({
  step,
  stepNumber,
  totalSteps,
  armed,
  detection,
  ambientHold,
  lastVerdict,
  lastRetake,
  stepNotice,
  roomToneReady,
  clientLevel,
  waveformPeaks,
  onStartStep,
  onStopTake,
  onRedoTake,
  onOverrideAmbientGate,
  onSkipStep,
  onRequestStartOver,
}: Props) {
  const [demoPlaying, setDemoPlaying] = useState(false);
  const [confirmingSkip, setConfirmingSkip] = useState(false);
  const audioRef = useRef<HTMLAudioElement | null>(null);

  useEffect(() => {
    setConfirmingSkip(false);
    return () => {
      audioRef.current?.pause();
    };
  }, [step.title]);

  function playDemo() {
    if (!step.demoReference) return;
    // `demoReference` is the native catalog's asset filename (`.aifc`, for the macOS app's
    // AVAudioPlayer) — browsers can't play AIFF-C at all, so `/demo` serves AAC (`.m4a`) versions
    // transcoded by web/scripts/transcode-demo-refs.sh under the same basename.
    const src = `/demo/${step.demoReference.replace(/\.aifc$/, ".m4a")}`;
    const audio = new Audio(src);
    audioRef.current = audio;
    setDemoPlaying(true);
    audio.addEventListener("ended", () => setDemoPlaying(false));
    audio.addEventListener("error", () => setDemoPlaying(false));
    void audio.play().catch(() => setDemoPlaying(false));
  }

  function stopDemo() {
    audioRef.current?.pause();
    setDemoPlaying(false);
  }

  const takeNumber = Math.min((detection?.takeIndex ?? 0) + 1, step.takes);
  const reviewing = detection?.phase === "reviewing";

  return (
    <div className="screen">
      <p className="progress-label">
        Step {stepNumber} of {totalSteps}
        {armed && ` · Take ${takeNumber} of ${step.takes}`}
      </p>
      <h1>{step.title}</h1>
      <p className="prompt">{step.prompt}</p>

      {step.demoReference && !armed && (
        <button className="secondary-button" onClick={demoPlaying ? stopDemo : playDemo}>
          {demoPlaying ? "Stop demo" : "Play demo"}
        </button>
      )}

      {roomToneReady && <p className="hint-text">Room tone captured ✓</p>}

      {!armed && !confirmingSkip && (
        <>
          <button className="primary-button record-button" onClick={onStartStep}>
            Start step
          </button>
          <button className="link-button" onClick={() => setConfirmingSkip(true)}>
            I don't know this technique — skip it
          </button>
        </>
      )}

      {!armed && confirmingSkip && (
        <div className="capture-status">
          <p className="warning-text">
            Skipping means we'll have no examples from you for "{step.title}" — that's completely
            fine if you've never learned it.
          </p>
          <button className="secondary-button" onClick={onSkipStep}>
            Yes, skip this step
          </button>
          <button className="secondary-button" onClick={() => setConfirmingSkip(false)}>
            Never mind, let me try
          </button>
        </div>
      )}

      {armed && (
        <div className="capture-status">
          {reviewing ? (
            <p>Checking take {takeNumber}…</p>
          ) : (
            <>
              <p>{phaseLabel(step, detection)}</p>
              {phaseFloorHint(step, detection) && (
                <p className="hint-text">{phaseFloorHint(step, detection)}</p>
              )}
              {eventCounterText(step, detection) && <p className="hint-text">{eventCounterText(step, detection)}</p>}
              {eventTargetReachedText(step, detection) && (
                <p className="hint-text">{eventTargetReachedText(step, detection)}</p>
              )}
              {durationGuidance(step) && <p className="hint-text">{durationGuidance(step)}</p>}
            </>
          )}
          <WaveformView peaks={waveformPeaks} />
          <LevelMeter level={detection?.level ?? clientLevel.rms} threshold={meterThreshold(detection)} active />
          {clientLevel.peak > 0.98 && (
            <p className="warning-text">Clipping — move back from the mic slightly.</p>
          )}
          {detection?.roomTooNoisy && (
            <p className="advisory-text">This room reads a bit loud — recordings may be noisier than ideal.</p>
          )}
          {ambientHold && (
            <p className="warning-text">
              Room's too noisy for the mic to tell breath from background right now.{" "}
              <button className="link-button" onClick={onOverrideAmbientGate}>
                It's actually fine, keep going
              </button>
            </p>
          )}
          {detection?.gapTooClose && (
            <p className="warning-text">Leave a clearer gap between hooks.</p>
          )}
          {!reviewing && lastRetake && (
            <p className="warning-text">That one {friendlyStructuralReason(lastRetake)} — redoing automatically.</p>
          )}
          {lastVerdict?.outcome === "redo" && (
            <p className="warning-text">That one {friendlyReason(lastVerdict.reason)} — redoing automatically.</p>
          )}
          {lastVerdict?.outcome === "keptUnchecked" && (
            <p className="hint-text">Take kept (not yet graded).</p>
          )}
          {lastVerdict?.outcome === "accepted" && <p className="hint-text">Take accepted.</p>}
          <button className="secondary-button" onClick={onStopTake}>
            Stop this take
          </button>
          <button className="link-button" onClick={onRedoTake}>
            Redo this take
          </button>
        </div>
      )}

      {stepNotice && <p className="advisory-text">{stepNotice}</p>}

      <button className="link-button" onClick={onRequestStartOver}>
        Start over
      </button>
    </div>
  );
}
