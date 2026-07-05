import { useEffect, useRef, useState } from "react";
import { LevelMeter } from "../components/LevelMeter";
import type { DetectionState, StepSnapshot, TakeVerdict } from "../ws/protocol";

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

interface Props {
  step: StepSnapshot;
  stepNumber: number;
  totalSteps: number;
  armed: boolean;
  detection: DetectionState | null;
  ambientHold: boolean;
  lastVerdict: TakeVerdict | null;
  stepNotice: string | null;
  roomToneReady: boolean;
  clientLevel: { rms: number; peak: number };
  onStartStep: () => void;
  onStopTake: () => void;
  onOverrideAmbientGate: () => void;
  onSkipStep: () => void;
  onRequestStartOver: () => void;
}

/** Fully server-driven — no manual record button. "Start step" arms the ported
 * `TakeCaptureEngine` on the server; takes self-terminate and auto-advance across the whole step
 * exactly as the native app, including automatic redo (a rejected take re-arms the same take index
 * without the participant doing anything). `onStopTake` is a visible escape hatch only. */
export function TechniqueStepScreen({
  step,
  stepNumber,
  totalSteps,
  armed,
  detection,
  ambientHold,
  lastVerdict,
  stepNotice,
  roomToneReady,
  clientLevel,
  onStartStep,
  onStopTake,
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

  const blackoutRemaining = detection?.blackoutRemaining ?? 0;
  const takeNumber = Math.min((detection?.takeIndex ?? 0) + 1, step.takes);

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
          {blackoutRemaining > 0 ? (
            <p>Get ready… {blackoutRemaining.toFixed(1)}s</p>
          ) : (
            <p>
              Listening… {detection?.eventCount ? `${detection.eventCount} event(s) so far` : ""}
            </p>
          )}
          <LevelMeter
            level={detection?.level ?? clientLevel.rms}
            threshold={detection?.activityThreshold}
            active
          />
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
        </div>
      )}

      {stepNotice && <p className="advisory-text">{stepNotice}</p>}

      <button className="link-button" onClick={onRequestStartOver}>
        Start over
      </button>
    </div>
  );
}
