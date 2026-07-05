export interface CaptureLevel {
  rms: number;
  peak: number;
}

/** One min/max bucket of the scrolling waveform — the server deliberately never sends raw samples
 * back (`TakeCaptureEngine` drops `wavePeaks` tracking on purpose: "the browser renders its own
 * cosmetic waveform from the samples it already has, at zero latency"), so this is built entirely
 * client-side from what `StreamingCapture` already has before it's sent as PCM. */
export interface WavePeak {
  min: number;
  max: number;
}

/** Drives one persistent mic session for the whole enrollment session: acquires the stream once,
 * keeps a live (cosmetic, client-local) level meter running from its own samples, and — once
 * `startStreaming` is called — converts every batch to Int16 LE PCM and forwards it. There is no
 * client-side take boundary, quiet-gap heuristic, or WAV encoding here; the server's ported
 * `TakeCaptureEngine` is the sole authority on arming, segmentation, and self-termination — this
 * class's only job is getting a continuous raw sample stream to the socket. */
/** Waveform bucket width — matched to a redraw-friendly resolution rather than any DSP need. */
const WAVEFORM_BUCKET_MS = 20;
/** History kept for the scrolling waveform (~4s) — old buckets fall off the front. */
const WAVEFORM_MAX_BUCKETS = 200;

export class StreamingCapture {
  private audioContext: AudioContext | null = null;
  private stream: MediaStream | null = null;
  private workletNode: AudioWorkletNode | null = null;
  private onLevel: ((level: CaptureLevel) => void) | null = null;
  private onWaveform: ((peaks: WavePeak[]) => void) | null = null;
  private onPCM: ((bytes: ArrayBufferLike) => void) | null = null;
  private streaming = false;

  private wavePeaks: WavePeak[] = [];
  private bucketSampleCount = 0;
  private bucketMin = 0;
  private bucketMax = 0;

  actualSettings: MediaTrackSettings | null = null;

  async initialize(
    onLevel: (level: CaptureLevel) => void,
    onWaveform: (peaks: WavePeak[]) => void,
  ): Promise<MediaTrackSettings> {
    this.onLevel = onLevel;
    this.onWaveform = onWaveform;
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

  /** Resets the scrolling waveform's history — called at the start of each new take so the display
   * doesn't carry over stale audio from whatever came before. */
  clearWaveform(): void {
    this.wavePeaks = [];
    this.bucketSampleCount = 0;
    this.bucketMin = 0;
    this.bucketMax = 0;
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
    const bucketFrames = Math.max(
      1,
      Math.round(((this.audioContext?.sampleRate ?? 44100) * WAVEFORM_BUCKET_MS) / 1000),
    );
    let bucketCompleted = false;
    for (let i = 0; i < batch.length; i++) {
      const v = batch[i];
      const abs = Math.abs(v);
      if (abs > peak) peak = abs;
      sumSq += v * v;

      if (this.bucketSampleCount === 0) {
        this.bucketMin = v;
        this.bucketMax = v;
      } else {
        if (v < this.bucketMin) this.bucketMin = v;
        if (v > this.bucketMax) this.bucketMax = v;
      }
      this.bucketSampleCount++;
      if (this.bucketSampleCount >= bucketFrames) {
        this.wavePeaks.push({ min: this.bucketMin, max: this.bucketMax });
        if (this.wavePeaks.length > WAVEFORM_MAX_BUCKETS) this.wavePeaks.shift();
        this.bucketSampleCount = 0;
        bucketCompleted = true;
      }
    }
    this.onLevel?.({ rms: Math.sqrt(sumSq / batch.length), peak });
    // Only notify on a completed bucket (not every worklet callback) — and always with a fresh array
    // reference (`wavePeaks` is mutated in place via push/shift), so a React state setter downstream
    // reliably detects the change instead of bailing out on an unchanged object identity.
    if (bucketCompleted) this.onWaveform?.(this.wavePeaks.slice());

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
