import type { ClientMessage, ServerMessage } from "./protocol";

type ServerMessageListener = (message: ServerMessage) => void;

/** One persistent WebSocket to `/api/sessions/:id/live` — the only participant-facing capture
 * path (see the plan: no more per-take REST upload). Owns framing (JSON control frames, binary
 * PCM frames) and exposes an unexpected-close hook so the caller can drive reconnect/resume; it
 * does not itself retry, since the caller needs to sequence that with re-arming local capture. */
export class EnrollmentSocket {
  private ws: WebSocket | null = null;
  private readonly listeners = new Set<ServerMessageListener>();
  private readonly url: string;
  private closedIntentionally = false;
  private opened = false;

  /** Fires once per unexpected close of an established connection (network drop, server restart)
   * — never for `close()`, and never for a connection that failed before ever opening (that's
   * `connect()`'s own rejection to handle, not a reconnect-worthy event). */
  onUnexpectedClose: (() => void) | null = null;

  constructor(sessionId: string) {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    this.url = `${proto}//${location.host}/api/sessions/${sessionId}/live`;
  }

  connect(): Promise<void> {
    this.closedIntentionally = false;
    this.opened = false;
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url);
      ws.binaryType = "arraybuffer";
      ws.onopen = () => {
        this.opened = true;
        resolve();
      };
      ws.onerror = () => {
        if (!this.opened) reject(new Error("WebSocket connection failed"));
      };
      ws.onmessage = (event) => {
        if (typeof event.data !== "string") return;
        let message: ServerMessage;
        try {
          message = JSON.parse(event.data) as ServerMessage;
        } catch {
          return;
        }
        this.listeners.forEach((listener) => listener(message));
      };
      ws.onclose = () => {
        if (this.opened && !this.closedIntentionally) this.onUnexpectedClose?.();
      };
      this.ws = ws;
    });
  }

  /** Returns an unsubscribe function. */
  onMessage(listener: ServerMessageListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  sendControl(message: ClientMessage): void {
    if (this.ws?.readyState !== WebSocket.OPEN) return;
    this.ws.send(JSON.stringify(message));
  }

  /** Raw Int16 LE mono PCM — the server's `EnrollmentSocketHandler.int16LEToFloat` decode path
   * assumes this exact layout. A silent no-op while not fully open — the continuous audio-worklet
   * callback keeps firing across a reconnect gap, and `WebSocket.send` throws (not queues) once the
   * socket is CLOSING/CLOSED, which would otherwise spam an exception on every single batch. */
  sendAudio(bytes: ArrayBufferLike): void {
    if (this.ws?.readyState !== WebSocket.OPEN) return;
    this.ws.send(bytes);
  }

  close(): void {
    this.closedIntentionally = true;
    this.ws?.close();
    this.ws = null;
  }
}
