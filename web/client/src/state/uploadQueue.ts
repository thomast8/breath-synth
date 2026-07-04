/** Fire-and-forget upload retry helper: recording the next take should never block on the network,
 * so uploads run in the background with a few retries before surfacing a failure. */
export interface QueuedUpload {
  id: string;
  label: string;
  status: "pending" | "uploading" | "done" | "failed";
  error?: string;
}

export type UploadQueueListener = (items: QueuedUpload[]) => void;

export class UploadQueue {
  private items = new Map<string, QueuedUpload>();
  private listeners = new Set<UploadQueueListener>();

  subscribe(listener: UploadQueueListener): () => void {
    this.listeners.add(listener);
    listener(this.snapshot());
    return () => this.listeners.delete(listener);
  }

  enqueue<T>(id: string, label: string, task: () => Promise<T>, maxAttempts = 3): Promise<T> {
    this.set(id, { id, label, status: "pending" });
    return this.runWithRetry(id, label, task, maxAttempts);
  }

  private async runWithRetry<T>(
    id: string,
    label: string,
    task: () => Promise<T>,
    attemptsLeft: number,
  ): Promise<T> {
    this.set(id, { id, label, status: "uploading" });
    try {
      const result = await task();
      this.set(id, { id, label, status: "done" });
      return result;
    } catch (error) {
      if (attemptsLeft > 1) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
        return this.runWithRetry(id, label, task, attemptsLeft - 1);
      }
      const message = error instanceof Error ? error.message : String(error);
      this.set(id, { id, label, status: "failed", error: message });
      throw error;
    }
  }

  private set(id: string, item: QueuedUpload): void {
    this.items.set(id, item);
    this.notify();
  }

  private snapshot(): QueuedUpload[] {
    return Array.from(this.items.values());
  }

  private notify(): void {
    const snapshot = this.snapshot();
    this.listeners.forEach((listener) => listener(snapshot));
  }
}
