export interface CaptureLevel {
  rms: number;
  peak: number;
}

/** Drives one persistent mic session for the whole enrollment session: acquires the stream once,
 * keeps a live (cosmetic, client-local) level meter running from its own samples, and — once
 * `startStreaming` is called — converts every batch to Int16 LE PCM and forwards it. There is no
 * client-side take boundary, quiet-gap heuristic, or WAV encoding here; the server's ported
 * `TakeCaptureEngine` is the sole authority on arming, segmentation, and self-termination — this
 * class's only job is getting a continuous raw sample stream to the socket. */
export class StreamingCapture {
  private audioContext: AudioContext | null = null;
  private stream: MediaStream | null = null;
  private workletNode: AudioWorkletNode | null = null;
  private onLevel: ((level: CaptureLevel) => void) | null = null;
  private onPCM: ((bytes: ArrayBufferLike) => void) | null = null;
  private streaming = false;

  actualSettings: MediaTrackSettings | null = null;

  async initialize(onLevel: (level: CaptureLevel) => void): Promise<MediaTrackSettings> {
    this.onLevel = onLevel;
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
        channelCount: 1,
      },
    });

    const track = this.stream.getAudioTracks()[0];
    this.actualSettings = track.getSettings();

    this.audioContext = new AudioContext();
    await this.audioContext.audioWorklet.addModule(
      new URL("./recorder-worklet.ts", import.meta.url),
    );
    const source = this.audioContext.createMediaStreamSource(this.stream);
    this.workletNode = new AudioWorkletNode(this.audioContext, "recorder-processor");

    this.workletNode.port.onmessage = (event: MessageEvent<Float32Array>) => {
      this.handleBatch(event.data);
    };
    source.connect(this.workletNode);

    return this.actualSettings;
  }

  get sampleRate(): number {
    return this.audioContext?.sampleRate ?? 44100;
  }

  /** Begins forwarding every subsequent batch as Int16 PCM to `onPCM` — call once the WebSocket
   * session is up. Level metering (via the `initialize` callback) runs unconditionally, before and
   * after this is called, since it's cosmetic only. */
  startStreaming(onPCM: (bytes: ArrayBufferLike) => void): void {
    this.onPCM = onPCM;
    this.streaming = true;
  }

  stopStreaming(): void {
    this.streaming = false;
    this.onPCM = null;
  }

  dispose(): void {
    this.stopStreaming();
    this.workletNode?.port.close();
    this.workletNode?.disconnect();
    this.stream?.getTracks().forEach((t) => t.stop());
    void this.audioContext?.close();
    this.audioContext = null;
    this.stream = null;
    this.workletNode = null;
  }

  private handleBatch(batch: Float32Array): void {
    let peak = 0;
    let sumSq = 0;
    for (let i = 0; i < batch.length; i++) {
      const v = Math.abs(batch[i]);
      if (v > peak) peak = v;
      sumSq += batch[i] * batch[i];
    }
    this.onLevel?.({ rms: Math.sqrt(sumSq / batch.length), peak });

    if (this.streaming && this.onPCM) {
      this.onPCM(floatToInt16LE(batch).buffer);
    }
  }
}

/** Same normalization as the server's `EnrollmentSocketHandler.int16LEToFloat`, inverted:
 * -1.0 -> -32768, just-under-1.0 -> 32767. Relies on the platform being little-endian (true for
 * every real-world browser target: x86/ARM), same implicit assumption the wire protocol makes. */
function floatToInt16LE(batch: Float32Array): Int16Array {
  const out = new Int16Array(batch.length);
  for (let i = 0; i < batch.length; i++) {
    const s = Math.max(-1, Math.min(1, batch[i]));
    out[i] = s < 0 ? s * 32768 : s * 32767;
  }
  return out;
}
