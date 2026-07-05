// Mirrors web/server/Sources/App/WebSocket/EnrollmentMessages.swift — kept in sync by inspection
// since the two live in different languages/packages. Every message is a flat tagged JSON object
// (`{"type": "...", ...}`); the server encodes each case's payload directly (no wrapper), and the
// client discriminates on `type` the same way the server's `ClientMessage` decoder does.

export type ClientMessage =
  | { type: "hello"; sampleRate: number; micSettings: Record<string, string> | null }
  | { type: "startStep"; stepIndex: number }
  | { type: "stopTake" }
  | { type: "redoTake" }
  | { type: "overrideAmbientGate" }
  | { type: "skipStep" }
  | { type: "resume"; lastAckedTake: number };

// `detection`/`isPairedRecovery` let the client reproduce native `BreathEnrollApp`'s per-kind phase
// label wording (e.g. bare "Inhale…" for event-counted kinds vs. "Inhaling… Xs" for `cycle`, and
// recovery's hook-breath lanes rendering like `cycle` even though their own detection kind isn't).
export type DetectionKind = "cycle" | "single" | "finalPhase" | "cleanEvents" | "naturalRhythm";

export interface StepSnapshot {
  title: string;
  prompt: string;
  demoReference: string | null;
  takes: number;
  minSeconds: number;
  maxSeconds: number;
  targetEvents: number | null;
  detection: DetectionKind;
  isPairedRecovery: boolean;
}

export type TakeVerdictOutcome = "accepted" | "redo" | "keptUnchecked" | "checking";

export interface DetectionState {
  phase: string;
  livePhase: string;
  // Seconds elapsed in the current `livePhase` — drives the native-mirrored phase label/floor hint.
  phaseElapsed: number;
  blackoutRemaining: number;
  level: number;
  activityThreshold: number;
  eventCount: number;
  takeIndex: number;
  gapTooClose: boolean;
  // Non-blocking "this room reads loud" caption — distinct from `ambientHold` (which actually blocks
  // onset detection until overridden).
  roomTooNoisy: boolean;
}

export interface TakeVerdict {
  outcome: TakeVerdictOutcome;
  takeIndex: number;
  reason: string | null;
}

// One of `"no_pause"`, `"inhale_too_short"`, `"exhale_too_short"`, `"phases_imbalanced"`,
// `"no_segment"`, `"no_pause_before_release"` — mirrors `CaptureAnalyzer.TakeIssue`.
export type TakeRetakeIssue =
  | "no_pause"
  | "inhale_too_short"
  | "exhale_too_short"
  | "phases_imbalanced"
  | "no_segment"
  | "no_pause_before_release";

export interface TakeRetake {
  takeIndex: number;
  issue: TakeRetakeIssue;
  //Only set for `"phases_imbalanced"` — the inhale:exhale duration ratio that tripped the guard.
  ratio: number | null;
  retries: number;
}

export type ServerMessage =
  | { type: "sessionState"; steps: StepSnapshot[]; currentStepIndex: number; stage: string }
  | ({ type: "detectionState" } & DetectionState)
  | { type: "ambientHold"; active: boolean }
  | ({ type: "takeRetake" } & TakeRetake)
  | ({ type: "takeVerdict" } & TakeVerdict)
  | { type: "stepComplete"; nextStepIndex: number; insertedFallbackNotice: string | null }
  | { type: "roomToneReady" }
  | { type: "sessionFinished" }
  | { type: "error"; message: string };
