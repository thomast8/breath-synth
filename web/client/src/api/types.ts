// Mirrors web/server/Sources/App/DTOs/Requests.swift and the Fluent models — kept in sync by
// inspection since the two live in different languages/packages.

export interface Participant {
  id: string;
  pseudonym: string | null;
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
  consentVersion: string;
}

export interface SessionCreateRequest {
  participantID: string;
  scriptVersion: string;
  sampleRate: number;
  userAgent: string | null;
  micConstraintsActual: Record<string, string> | null;
}
