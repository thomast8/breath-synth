/** Resume-where-you-left-off state, keyed in localStorage so a reload/crash mid-session doesn't
 * lose the participant/session identity. Deliberately minimal — step/take progress lives entirely
 * server-side now (the `sessionState` message on reconnect is the source of truth), so this only
 * needs to avoid re-asking for consent. */
export interface PersistedProgress {
  participantId: string;
  sessionId: string;
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
