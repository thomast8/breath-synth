import { useEffect, useRef, useState } from "react";
import { ConsentScreen } from "./screens/ConsentScreen";
import { ResumeChoiceScreen } from "./screens/ResumeChoiceScreen";
import { MicCheckScreen } from "./screens/MicCheckScreen";
import { TechniqueStepScreen } from "./screens/TechniqueStepScreen";
import { DoneScreen } from "./screens/DoneScreen";
import { StreamingCapture, type CaptureLevel } from "./audio/StreamingCapture";
import { EnrollmentSocket } from "./ws/EnrollmentSocket";
import { clearProgress, loadProgress, saveProgress } from "./state/persistence";
import { completeSession, createParticipant, createSession, deleteParticipant, ApiError } from "./api/client";
import type { DetectionState, ServerMessage, StepSnapshot, TakeVerdict } from "./ws/protocol";

type Stage = "consent" | "resume-choice" | "mic-init" | "technique" | "done";

const INVITE_CODE_REQUIRED = true;
// Just a version tag stamped on EnrollSession for later inspection — the client no longer owns a
// step catalog (that's the server's `sessionState` message now), so this isn't tied to one.
const CLIENT_SCRIPT_VERSION = "web-v2";

export default function App() {
  const [stage, setStage] = useState<Stage>("consent");
  const [participantId, setParticipantId] = useState<string | null>(null);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [level, setLevel] = useState<CaptureLevel>({ rms: 0, peak: 0 });
  const [micReady, setMicReady] = useState(false);
  const [micError, setMicError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [steps, setSteps] = useState<StepSnapshot[]>([]);
  const [currentStepIndex, setCurrentStepIndex] = useState(0);
  const [armed, setArmed] = useState(false);
  const [detection, setDetection] = useState<DetectionState | null>(null);
  const [ambientHold, setAmbientHold] = useState(false);
  const [lastVerdict, setLastVerdict] = useState<TakeVerdict | null>(null);
  const [stepNotice, setStepNotice] = useState<string | null>(null);
  const [roomToneReady, setRoomToneReady] = useState(false);
  const [confirmingStartOver, setConfirmingStartOver] = useState(false);

  const capture = useRef(new StreamingCapture()).current;
  const socketRef = useRef<EnrollmentSocket | null>(null);
  const finishedRef = useRef(false);
  const resumed = useRef(false);
  const reconnectAttemptRef = useRef(0);
  /** True once a `sessionState` has ever arrived for this session — proof the session genuinely
   * exists server-side. A close before that ever happens (stale/deleted session referenced from
   * localStorage, wrong ID, etc.) is a permanent failure retrying can never fix, not a transient
   * drop worth the reconnect-with-backoff treatment. */
  const sessionValidatedRef = useRef(false);

  useEffect(() => {
    if (resumed.current) return;
    resumed.current = true;
    const saved = loadProgress();
    if (saved) {
      setParticipantId(saved.participantId);
      setSessionId(saved.sessionId);
      // An explicit choice rather than silently auto-resuming — jumping straight past consent
      // could be surprising (a different person on a shared machine, a much later revisit), and
      // there was previously no way to deliberately abandon stale progress and start fresh.
      setStage("resume-choice");
    }
  }, []);

  useEffect(() => {
    return () => {
      capture.dispose();
      socketRef.current?.close();
    };
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

  function resumePrevious() {
    setStage("mic-init");
    void initMic();
  }

  /** Abandons whatever's currently in progress (best-effort marks the old session `abandoned`
   * server-side, so it doesn't sit looking mysteriously incomplete forever) and returns to a clean
   * consent screen. Reachable from the resume choice screen and, via `onRequestStartOver` +
   * `confirmingStartOver`'s confirm step, from mid-flow at any point. */
  async function startOver() {
    const abandonedParticipantId = participantId;
    capture.dispose();
    socketRef.current?.close();
    socketRef.current = null;
    clearProgress();
    setParticipantId(null);
    setSessionId(null);
    setMicReady(false);
    setMicError(null);
    setSteps([]);
    setCurrentStepIndex(0);
    setArmed(false);
    setDetection(null);
    setAmbientHold(false);
    setLastVerdict(null);
    setStepNotice(null);
    setRoomToneReady(false);
    setError(null);
    setConfirmingStartOver(false);
    setStage("consent");
    if (abandonedParticipantId) {
      try {
        // Actually delete the abandoned attempt, not just relabel it — nothing in the admin/export
        // pipeline filters on session status (`SessionExporter` only checks per-take `status ==
        // .kept`), so a merely-"abandoned" session would still be fully exportable, silently
        // carrying a discarded partial attempt into the corpus. This flow always creates a brand
        // new participant on the next attempt anyway, so there's nothing worth keeping. Reuses the
        // same self-serve deletion endpoint the done screen's "delete my data" link uses.
        await deleteParticipant(abandonedParticipantId);
      } catch {
        // Best-effort — the participant is starting fresh regardless of whether this lands.
      }
    }
  }

  async function handleConsent(fields: {
    inviteCode: string | null;
    pseudonym: string | null;
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
        scriptVersion: CLIENT_SCRIPT_VERSION,
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
      saveProgress({ participantId: participant.id, sessionId: session.id });
    } catch (e) {
      setError(e instanceof ApiError ? e.message : e instanceof Error ? e.message : String(e));
      setStage("consent");
    } finally {
      setSubmitting(false);
    }
  }

  function handleServerMessage(sid: string) {
    return (msg: ServerMessage) => {
      switch (msg.type) {
        case "sessionState":
          sessionValidatedRef.current = true;
          reconnectAttemptRef.current = 0;
          setSteps(msg.steps);
          setCurrentStepIndex(msg.currentStepIndex);
          if (msg.stage === "finished") void finishSession(sid);
          break;
        case "detectionState":
          setDetection({
            phase: msg.phase,
            livePhase: msg.livePhase,
            blackoutRemaining: msg.blackoutRemaining,
            level: msg.level,
            activityThreshold: msg.activityThreshold,
            eventCount: msg.eventCount,
            takeIndex: msg.takeIndex,
            gapTooClose: msg.gapTooClose,
          });
          // `armed` is otherwise only ever set locally (on `onStartStep`) — on a page reload or a
          // reconnect after a drop, the server may already be mid-capture for this step with no
          // local state to reflect that. Any non-idle phase is authoritative proof the server
          // considers this step armed, so let it correct the UI rather than trusting local state.
          if (msg.phase !== "idle") setArmed(true);
          break;
        case "ambientHold":
          setAmbientHold(msg.active);
          break;
        case "takeVerdict":
          setLastVerdict({ outcome: msg.outcome, takeIndex: msg.takeIndex, reason: msg.reason });
          break;
        case "stepComplete":
          setCurrentStepIndex(msg.nextStepIndex);
          setStepNotice(msg.insertedFallbackNotice);
          setArmed(false);
          setLastVerdict(null);
          setDetection(null);
          break;
        case "roomToneReady":
          setRoomToneReady(true);
          break;
        case "sessionFinished":
          void finishSession(sid);
          break;
        case "error":
          setError(msg.message);
          break;
      }
    };
  }

  const MAX_RECONNECT_ATTEMPTS = 5;

  async function connectSocket(sid: string) {
    const socket = new EnrollmentSocket(sid);
    socket.onMessage(handleServerMessage(sid));
    socket.onUnexpectedClose = () => {
      if (!sessionValidatedRef.current) {
        // Never got a sessionState back — the server closed us before ever validating the session
        // exists. That's permanent (a stale/deleted session referenced from localStorage, or a bad
        // ID), not a network blip; no amount of retrying fixes it, so stop immediately instead of
        // looping forever with a fixed 1s delay (what a hardcoded `reconnectWithBackoff(sid, 0)`
        // here actually did — every close reset the attempt counter, so it never hit the cap).
        handleInvalidSession();
        return;
      }
      reconnectAttemptRef.current += 1;
      void reconnectWithBackoff(sid, reconnectAttemptRef.current);
    };
    await socket.connect();
    socket.sendControl({ type: "hello", sampleRate: capture.sampleRate, micSettings: null });
    // Always redo-current-take on (re)connect, not just when we locally believe we were armed —
    // a page reload starts with no local memory of server-side state at all, and `resume` (which
    // just triggers `redoCurrentTake()` server-side) is a documented no-op when nothing is
    // actually in progress, so unconditionally sending it is strictly safer than trying to guess.
    socket.sendControl({ type: "resume", lastAckedTake: 0 });
    socketRef.current = socket;
  }

  async function reconnectWithBackoff(sid: string, attempt: number) {
    if (attempt > MAX_RECONNECT_ATTEMPTS) {
      setError("Lost connection to the server and could not reconnect — reload to try again.");
      return;
    }
    const delayMs = Math.min(1000 * 2 ** (attempt - 1), 15000);
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    try {
      await connectSocket(sid);
    } catch {
      reconnectAttemptRef.current += 1;
      await reconnectWithBackoff(sid, reconnectAttemptRef.current);
    }
  }

  /** The referenced session doesn't exist server-side — tear down cleanly and send the participant
   * back to consent rather than leaving them stuck on a "Connecting…" screen forever. */
  function handleInvalidSession() {
    capture.stopStreaming();
    socketRef.current?.close();
    clearProgress();
    setSteps([]);
    setSessionId(null);
    setParticipantId(null);
    setError("This session could not be found — it may have expired or been deleted. Please start over.");
    setStage("consent");
  }

  async function beginTechnique() {
    if (!sessionId) return;
    setError(null);
    setConnecting(true);
    try {
      await connectSocket(sessionId);
      capture.startStreaming((bytes) => socketRef.current?.sendAudio(bytes));
      setStage("technique");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setConnecting(false);
    }
  }

  function onStartStep() {
    socketRef.current?.sendControl({ type: "startStep", stepIndex: currentStepIndex });
    setArmed(true);
    setLastVerdict(null);
    setStepNotice(null);
  }

  function onStopTake() {
    socketRef.current?.sendControl({ type: "stopTake" });
  }

  function onOverrideAmbientGate() {
    socketRef.current?.sendControl({ type: "overrideAmbientGate" });
  }

  function onSkipStep() {
    socketRef.current?.sendControl({ type: "skipStep" });
  }

  async function finishSession(sid: string) {
    if (finishedRef.current) return;
    finishedRef.current = true;
    try {
      await completeSession(sid, "completed");
    } catch {
      // Best-effort — takes are already accepted/persisted server-side; don't block the
      // thank-you screen on this final status flip.
    }
    capture.dispose();
    socketRef.current?.close();
    clearProgress();
    setStage("done");
  }

  // Overrides whatever stage is showing — a start-over request can come from mid-flow (mic-init or
  // any technique step), not just the resume-choice screen.
  if (confirmingStartOver) {
    return (
      <div className="screen">
        <h1>Start over?</h1>
        <p className="warning-text">
          This permanently deletes any takes you've already recorded in this attempt and begins a
          brand new enrollment from scratch — there's no undo.
        </p>
        <button className="primary-button" onClick={() => void startOver()}>
          Yes, start over
        </button>
        <button className="secondary-button" onClick={() => setConfirmingStartOver(false)}>
          Never mind
        </button>
      </div>
    );
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

  if (stage === "resume-choice") {
    return <ResumeChoiceScreen onResume={resumePrevious} onStartOver={() => void startOver()} />;
  }

  if (stage === "mic-init") {
    return (
      <MicCheckScreen
        capture={capture}
        level={level}
        micReady={micReady}
        micError={micError}
        connecting={connecting}
        error={error}
        onContinue={beginTechnique}
        onRequestStartOver={() => setConfirmingStartOver(true)}
      />
    );
  }

  if (stage === "technique" && sessionId) {
    if (steps.length === 0) {
      return <div className="screen">Connecting…</div>;
    }
    const step = steps[currentStepIndex];
    return (
      <TechniqueStepScreen
        step={step}
        stepNumber={currentStepIndex + 1}
        totalSteps={steps.length}
        armed={armed}
        detection={detection}
        ambientHold={ambientHold}
        lastVerdict={lastVerdict}
        stepNotice={stepNotice}
        roomToneReady={roomToneReady}
        clientLevel={level}
        onStartStep={onStartStep}
        onStopTake={onStopTake}
        onOverrideAmbientGate={onOverrideAmbientGate}
        onSkipStep={onSkipStep}
        onRequestStartOver={() => setConfirmingStartOver(true)}
      />
    );
  }

  if (stage === "done" && sessionId && participantId) {
    const totalTakes = steps.reduce((sum, s) => sum + s.takes, 0);
    return <DoneScreen participantId={participantId} sessionId={sessionId} totalTakes={totalTakes} />;
  }

  return <div className="screen">Loading…</div>;
}
