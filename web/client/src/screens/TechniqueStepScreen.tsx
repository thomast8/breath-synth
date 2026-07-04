import { useEffect, useRef, useState } from "react";
import { LevelMeter } from "../components/LevelMeter";
import { uploadTake } from "../api/client";
import type { CaptureController, CaptureEndReason } from "../audio/CaptureController";
import type { UploadQueue } from "../state/uploadQueue";
import type { Step } from "../script";

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
  step: Step;
  stepNumber: number;
  totalSteps: number;
  sessionId: string;
  capture: CaptureController;
  level: { rms: number; peak: number };
  uploadQueue: UploadQueue;
  onStepComplete: () => void;
}

type Phase = "idle" | "recording" | "checking" | "redo";

export function TechniqueStepScreen({
  step,
  stepNumber,
  totalSteps,
  sessionId,
  capture,
  level,
  uploadQueue,
  onStepComplete,
}: Props) {
  const [takeNumber, setTakeNumber] = useState(1);
  const [phase, setPhase] = useState<Phase>("idle");
  const [elapsed, setElapsed] = useState(0);
  const [redoReason, setRedoReason] = useState<string | null>(null);
  const [advisory, setAdvisory] = useState<string[]>([]);
  const [demoPlaying, setDemoPlaying] = useState(false);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const elapsedTimer = useRef<number | null>(null);
  const finishHandlerRef = useRef<((reason: CaptureEndReason) => void) | null>(null);

  useEffect(() => {
    setTakeNumber(1);
    setPhase("idle");
    setRedoReason(null);
    setAdvisory([]);
  }, [step.id]);

  useEffect(() => {
    return () => {
      if (elapsedTimer.current != null) window.clearInterval(elapsedTimer.current);
    };
  }, []);

  function playDemo() {
    if (!step.demoReference) return;
    const audio = new Audio(`/demo/${step.demoReference}`);
    audioRef.current = audio;
    setDemoPlaying(true);
    audio.addEventListener("ended", () => setDemoPlaying(false));
    void audio.play();
  }

  function stopDemo() {
    audioRef.current?.pause();
    setDemoPlaying(false);
  }

  async function uploadTakeToAllLanes(blob: Blob, sampleRate: number) {
    const results = await Promise.all(
      step.lanes.map((lane) =>
        uploadQueue.enqueue(
          `${sessionId}-${lane.slug}-${lane.role}-${takeNumber}-${Date.now()}`,
          `${step.title} take ${takeNumber}`,
          () =>
            uploadTake(sessionId, blob, {
              stepSlug: step.id,
              laneSlug: lane.slug,
              style: lane.style,
              breathType: lane.type,
              renderMode: lane.renderMode,
              role: lane.role,
              takeIndex: takeNumber,
              reference: lane.reference,
              minSeconds: step.minSeconds,
              maxSeconds: step.maxSeconds,
              sampleRate,
              clientMeta: null,
            }),
        ),
      ),
    );

    const rejected = results.find((r) => !r.accept);
    const allAdvisory = Array.from(new Set(results.flatMap((r) => r.advisory)));
    setAdvisory(allAdvisory);

    if (rejected) {
      setRedoReason(rejected.reason);
      setPhase("redo");
      return;
    }

    setRedoReason(null);
    if (takeNumber >= step.takes) {
      onStepComplete();
    } else {
      setTakeNumber((n) => n + 1);
      setPhase("idle");
    }
  }

  function startRecording() {
    stopDemo();
    setPhase("recording");
    setElapsed(0);
    elapsedTimer.current = window.setInterval(() => setElapsed((e) => e + 0.2), 200);

    const finish = (reason: CaptureEndReason) => {
      if (elapsedTimer.current != null) {
        window.clearInterval(elapsedTimer.current);
        elapsedTimer.current = null;
      }
      finishHandlerRef.current = null;
      const result = capture.finishTake(reason);
      setPhase("checking");
      void uploadTakeToAllLanes(result.blob, result.sampleRate);
    };
    finishHandlerRef.current = finish;

    capture.startTake(step.minSeconds, step.maxSeconds, () => finish("auto"));
  }

  function finishTakeManually() {
    finishHandlerRef.current?.("manual");
  }

  return (
    <div className="screen">
      <p className="progress-label">
        Step {stepNumber} of {totalSteps} · Take {Math.min(takeNumber, step.takes)} of {step.takes}
      </p>
      <h1>{step.title}</h1>
      <p className="prompt">{step.prompt}</p>

      {step.demoReference && phase === "idle" && (
        <button className="secondary-button" onClick={demoPlaying ? stopDemo : playDemo}>
          {demoPlaying ? "Stop demo" : "Play demo"}
        </button>
      )}

      {phase === "idle" && (
        <button className="primary-button record-button" onClick={startRecording}>
          Start recording
        </button>
      )}

      {phase === "recording" && (
        <div className="capture-status">
          <p>Recording… {elapsed.toFixed(1)}s</p>
          <LevelMeter rms={level.rms} active />
          <button className="secondary-button" onClick={finishTakeManually}>
            Finish this take
          </button>
        </div>
      )}

      {phase === "checking" && <p>Checking take…</p>}

      {phase === "redo" && (
        <div className="capture-status">
          <p className="warning-text">That one {friendlyReason(redoReason)} — let's try again.</p>
          <button className="primary-button" onClick={startRecording}>
            Record again
          </button>
        </div>
      )}

      {advisory.length > 0 && phase === "idle" && (
        <p className="advisory-text">Kept — the final build re-checks: {advisory.join(", ")}</p>
      )}
    </div>
  );
}
