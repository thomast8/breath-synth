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

export interface StepSnapshot {
  title: string;
  prompt: string;
  demoReference: string | null;
  takes: number;
  minSeconds: number;
  maxSeconds: number;
  targetEvents: number | null;
}

export type TakeVerdictOutcome = "accepted" | "redo" | "keptUnchecked" | "checking";

export interface DetectionState {
  phase: string;
  livePhase: string;
  blackoutRemaining: number;
  level: number;
  activityThreshold: number;
  eventCount: number;
  takeIndex: number;
  gapTooClose: boolean;
}

export interface TakeVerdict {
  outcome: TakeVerdictOutcome;
  takeIndex: number;
  reason: string | null;
}

export type ServerMessage =
  | { type: "sessionState"; steps: StepSnapshot[]; currentStepIndex: number; stage: string }
  | ({ type: "detectionState" } & DetectionState)
  | { type: "ambientHold"; active: boolean }
  | ({ type: "takeVerdict" } & TakeVerdict)
  | { type: "stepComplete"; nextStepIndex: number; insertedFallbackNotice: string | null }
  | { type: "roomToneReady" }
  | { type: "sessionFinished" }
  | { type: "error"; message: string };
