/** Resume-where-you-left-off state, keyed in localStorage so a reload/crash mid-session doesn't
 * lose the participant/session identity or step progress. Deliberately minimal — the server is the
 * source of truth for what's actually been uploaded; this just avoids re-asking for consent and
 * re-walking completed steps. */
export interface PersistedProgress {
  participantId: string;
  sessionId: string;
  roomToneDone: boolean;
  stepIndex: number;
}

const KEY = "breath-enroll-progress";

export function loadProgress(): PersistedProgress | null {
  const raw = localStorage.getItem(KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as PersistedProgress;
  } catch {
    return null;
  }
}

export function saveProgress(progress: PersistedProgress): void {
  localStorage.setItem(KEY, JSON.stringify(progress));
}

export function clearProgress(): void {
  localStorage.removeItem(KEY);
}
