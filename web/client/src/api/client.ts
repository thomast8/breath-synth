import type {
  EnrollSession,
  Participant,
  ParticipantCreateRequest,
  SessionCreateRequest,
  SessionStatus,
  TakeUploadFields,
  TakeVerdictResponse,
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

export async function uploadRoomTone(
  sessionID: string,
  audio: Blob,
  sampleRate: number,
): Promise<EnrollSession> {
  const form = new FormData();
  form.append("sampleRate", String(sampleRate));
  form.append("audio", audio, "room_tone.wav");
  const res = await fetch(`/api/sessions/${sessionID}/room-tone`, { method: "POST", body: form });
  return asJSON<EnrollSession>(res);
}

export async function uploadTake(
  sessionID: string,
  audio: Blob,
  fields: TakeUploadFields,
): Promise<TakeVerdictResponse> {
  const form = new FormData();
  form.append("stepSlug", fields.stepSlug);
  form.append("laneSlug", fields.laneSlug);
  form.append("style", fields.style);
  form.append("breathType", fields.breathType);
  form.append("renderMode", fields.renderMode);
  form.append("role", fields.role);
  form.append("takeIndex", String(fields.takeIndex));
  if (fields.reference != null) form.append("reference", fields.reference);
  if (fields.minSeconds != null) form.append("minSeconds", String(fields.minSeconds));
  if (fields.maxSeconds != null) form.append("maxSeconds", String(fields.maxSeconds));
  form.append("sampleRate", String(fields.sampleRate));
  form.append("audio", audio, `${fields.laneSlug}_take${fields.takeIndex}.wav`);
  const res = await fetch(`/api/sessions/${sessionID}/takes`, { method: "POST", body: form });
  return asJSON<TakeVerdictResponse>(res);
}

export async function completeSession(
  sessionID: string,
  status: SessionStatus,
): Promise<EnrollSession> {
  return postJSON<EnrollSession>(`/api/sessions/${sessionID}/complete`, { status });
}

export { ApiError };
