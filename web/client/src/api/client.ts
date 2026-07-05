import type {
  EnrollSession,
  Participant,
  ParticipantCreateRequest,
  SessionCreateRequest,
  SessionStatus,
} from "./types";

class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

async function asJSON<T>(res: Response): Promise<T> {
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new ApiError(res.status, text || res.statusText);
  }
  return (await res.json()) as T;
}

async function postJSON<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return asJSON<T>(res);
}

export async function createParticipant(req: ParticipantCreateRequest): Promise<Participant> {
  return postJSON<Participant>("/api/participants", req);
}

export async function createSession(req: SessionCreateRequest): Promise<EnrollSession> {
  return postJSON<EnrollSession>("/api/sessions", req);
}

export async function completeSession(
  sessionID: string,
  status: SessionStatus,
): Promise<EnrollSession> {
  return postJSON<EnrollSession>(`/api/sessions/${sessionID}/complete`, { status });
}

/** Self-serve deletion — the participant's own ID is the sole capability token (no other auth).
 * Cascades server-side through their sessions, takes, and stored audio. */
export async function deleteParticipant(participantID: string): Promise<void> {
  const res = await fetch(`/api/participants/${participantID}`, { method: "DELETE" });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new ApiError(res.status, text || res.statusText);
  }
}

export { ApiError };
