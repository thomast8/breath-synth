// Mirrors web/server/Sources/App/DTOs/Requests.swift and the Fluent models — kept in sync by
// inspection since the two live in different languages/packages.

export type ExperienceLevel = "novice" | "intermediate" | "advanced" | "instructor";

export interface Participant {
  id: string;
  pseudonym: string | null;
  experienceLevel: ExperienceLevel;
  consentVersion: string;
  consentedAt: string;
  createdAt: string | null;
}

export type SessionStatus = "in_progress" | "completed" | "abandoned";

export interface EnrollSession {
  id: string;
  status: SessionStatus;
  scriptVersion: string;
  sampleRate: number;
  userAgent: string | null;
  micConstraintsActual: Record<string, string> | null;
  roomToneObjectKey: string | null;
  startedAt: string | null;
  completedAt: string | null;
}

export interface ParticipantCreateRequest {
  inviteCode: string | null;
  pseudonym: string | null;
  experienceLevel: ExperienceLevel;
  consentVersion: string;
}

export interface SessionCreateRequest {
  participantID: string;
  scriptVersion: string;
  sampleRate: number;
  userAgent: string | null;
  micConstraintsActual: Record<string, string> | null;
}

export interface TakeVerdictResponse {
  takeID: string;
  accept: boolean;
  reason: string | null;
  advisory: string[];
  fragmentsAccepted: number;
  fragmentsTotal: number;
}

export type BreathType = "inhale" | "exhale";
export type RenderMode = "textured" | "oneShot" | "counted";

export interface TakeUploadFields {
  stepSlug: string;
  laneSlug: string;
  style: string;
  breathType: BreathType;
  renderMode: RenderMode;
  role: string;
  takeIndex: number;
  reference: string | null;
  minSeconds: number | null;
  maxSeconds: number | null;
  sampleRate: number;
  clientMeta: Record<string, string> | null;
}
