import { useEffect, useRef, useState } from "react";
import { ConsentScreen } from "./screens/ConsentScreen";
import { MicCheckScreen } from "./screens/MicCheckScreen";
import { TechniqueStepScreen } from "./screens/TechniqueStepScreen";
import { DoneScreen } from "./screens/DoneScreen";
import { CaptureController, type CaptureLevel } from "./audio/CaptureController";
import { UploadQueue } from "./state/uploadQueue";
import { clearProgress, loadProgress, saveProgress } from "./state/persistence";
import { completeSession, createParticipant, createSession, uploadRoomTone, ApiError } from "./api/client";
import { STEPS, SCRIPT_VERSION } from "./script";
import type { ExperienceLevel } from "./api/types";

type Stage = "consent" | "mic-init" | "room-tone" | "technique" | "done";

const INVITE_CODE_REQUIRED = true;

export default function App() {
  const [stage, setStage] = useState<Stage>("consent");
  const [participantId, setParticipantId] = useState<string | null>(null);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [stepIndex, setStepIndex] = useState(0);
  const [level, setLevel] = useState<CaptureLevel>({ rms: 0, peak: 0 });
  const [micReady, setMicReady] = useState(false);
  const [micError, setMicError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const capture = useRef(new CaptureController()).current;
  const uploadQueue = useRef(new UploadQueue()).current;
  const resumed = useRef(false);

  useEffect(() => {
    if (resumed.current) return;
    resumed.current = true;
    const saved = loadProgress();
    if (saved) {
      setParticipantId(saved.participantId);
      setSessionId(saved.sessionId);
      setStepIndex(saved.stepIndex);
      setStage(saved.roomToneDone ? "technique" : "mic-init");
      void initMic();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    return () => capture.dispose();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function initMic() {
    try {
      await capture.initialize(setLevel);
      setMicReady(true);
    } catch (e) {
      setMicError(e instanceof Error ? e.message : String(e));
    }
  }

  async function handleConsent(fields: {
    inviteCode: string | null;
    pseudonym: string | null;
    experienceLevel: ExperienceLevel;
    consentVersion: string;
  }) {
    setSubmitting(true);
    setError(null);
    try {
      const participant = await createParticipant(fields);
      setStage("mic-init");
      await initMic();
      const settings = capture.actualSettings;
      const session = await createSession({
        participantID: participant.id,
        scriptVersion: SCRIPT_VERSION,
        sampleRate: capture.sampleRate,
        userAgent: navigator.userAgent,
        micConstraintsActual: settings
          ? {
              echoCancellation: String(settings.echoCancellation ?? ""),
              noiseSuppression: String(settings.noiseSuppression ?? ""),
              autoGainControl: String(settings.autoGainControl ?? ""),
              sampleRate: String(settings.sampleRate ?? ""),
            }
          : null,
      });
      setParticipantId(participant.id);
      setSessionId(session.id);
      saveProgress({
        participantId: participant.id,
        sessionId: session.id,
        roomToneDone: false,
        stepIndex: 0,
      });
      setStage("room-tone");
    } catch (e) {
      setError(e instanceof ApiError ? e.message : e instanceof Error ? e.message : String(e));
      setStage("consent");
    } finally {
      setSubmitting(false);
    }
  }

  async function handleRoomToneReady(blob: Blob, sampleRate: number) {
    if (!sessionId || !participantId) return;
    setSubmitting(true);
    setError(null);
    try {
      await uploadRoomTone(sessionId, blob, sampleRate);
      saveProgress({ participantId, sessionId, roomToneDone: true, stepIndex: 0 });
      setStage("technique");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  function handleStepComplete() {
    if (!participantId || !sessionId) return;
    const next = stepIndex + 1;
    if (next >= STEPS.length) {
      void finishSession();
      return;
    }
    setStepIndex(next);
    saveProgress({ participantId, sessionId, roomToneDone: true, stepIndex: next });
  }

  async function finishSession() {
    if (!sessionId) return;
    try {
      await completeSession(sessionId, "completed");
    } catch {
      // Best-effort — the takes are already uploaded and gradeable regardless of whether this
      // final status flip lands; don't block the thank-you screen on it.
    }
    clearProgress();
    setStage("done");
  }

  if (stage === "consent") {
    return (
      <ConsentScreen
        requiresInviteCode={INVITE_CODE_REQUIRED}
        onSubmit={handleConsent}
        error={error}
        submitting={submitting}
      />
    );
  }

  if (stage === "mic-init") {
    return (
      <MicCheckScreen
        capture={capture}
        level={level}
        micReady={micReady}
        micError={micError}
        onReady={handleRoomToneReady}
        error={error}
        uploading={submitting}
      />
    );
  }

  if (stage === "room-tone") {
    return (
      <MicCheckScreen
        capture={capture}
        level={level}
        micReady={micReady}
        micError={micError}
        onReady={handleRoomToneReady}
        error={error}
        uploading={submitting}
      />
    );
  }

  if (stage === "technique" && sessionId) {
    const step = STEPS[stepIndex];
    return (
      <TechniqueStepScreen
        step={step}
        stepNumber={stepIndex + 1}
        totalSteps={STEPS.length}
        sessionId={sessionId}
        capture={capture}
        level={level}
        uploadQueue={uploadQueue}
        onStepComplete={handleStepComplete}
      />
    );
  }

  if (stage === "done" && sessionId) {
    const totalTakes = STEPS.reduce((sum, s) => sum + s.takes * s.lanes.length, 0);
    return <DoneScreen sessionId={sessionId} totalTakes={totalTakes} />;
  }

  return <div className="screen">Loading…</div>;
}
