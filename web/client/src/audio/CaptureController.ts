import { encodeWavPCM16 } from "./encodeWav";

export interface CaptureLevel {
  rms: number;
  peak: number;
}

export type CaptureEndReason = "auto" | "manual" | "maxDuration";

export interface CaptureResult {
  blob: Blob;
  durationSec: number;
  sampleRate: number;
  endReason: CaptureEndReason;
  clipped: boolean;
  peak: number;
  rms: number;
}

const WINDOW_SEC = 0.1;
/// Deliberately uncalibrated and generous: this only decides when the browser stops *recording*,
/// not whether the take is good — the server's CaptureAnalyzer-derived grading is authoritative.
/// A fixed absolute floor is fine because the only failure modes are "stops a bit late" (harmless,
/// the server trims) or "never auto-stops" (the manual finish button and the hard maxSeconds cap
/// both catch that).
const QUIET_RMS_THRESHOLD = 0.02;
const QUIET_STREAK_SEC = 1.5;

/** Drives one persistent mic session across every take in an enrollment session: acquires the
 * stream once, keeps a live level meter running, and turns each `startTake`/`finishTake` pair into
 * an encoded WAV blob. The quiet-gap auto-stop is a coarse client-side convenience only — actual
 * phase/event segmentation happens server-side against the real recording. */
export class CaptureController {
  private audioContext: AudioContext | null = null;
  private stream: MediaStream | null = null;
  private workletNode: AudioWorkletNode | null = null;
  private onLevel: ((level: CaptureLevel) => void) | null = null;
  private onAutoStop: (() => void) | null = null;

  private recording = false;
  private chunks: Float32Array[] = [];
  private sampleCount = 0;
  private quietStreakFrames = 0;
  private windowFrames = 0;
  private maxFrames = 0;
  private minFrames = 0;
  private windowSumSquares = 0;
  private windowSampleCount = 0;
  private takePeak = 0;
  private takeSumSquares = 0;
  private takeSampleTotal = 0;

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
    this.windowFrames = Math.round(this.audioContext.sampleRate * WINDOW_SEC);

    this.workletNode.port.onmessage = (event: MessageEvent<Float32Array>) => {
      this.handleBatch(event.data);
    };
    source.connect(this.workletNode);

    return this.actualSettings;
  }

  get sampleRate(): number {
    return this.audioContext?.sampleRate ?? 44100;
  }

  /** Begins accumulating samples for a new take. `onAutoStop` fires once (from inside a message
   * handler, not synchronously) when the quiet-gap heuristic decides the take is done; the caller
   * is still responsible for calling `finishTake()` in response. */
  startTake(minSeconds: number, maxSeconds: number, onAutoStop: () => void): void {
    this.chunks = [];
    this.sampleCount = 0;
    this.quietStreakFrames = 0;
    this.windowSumSquares = 0;
    this.windowSampleCount = 0;
    this.takePeak = 0;
    this.takeSumSquares = 0;
    this.takeSampleTotal = 0;
    this.minFrames = Math.round(minSeconds * this.sampleRate);
    this.maxFrames = Math.round(maxSeconds * this.sampleRate);
    this.onAutoStop = onAutoStop;
    this.recording = true;
  }

  /** Manual escape hatch (and the auto-stop / max-duration paths funnel through here too) —
   * finalizes whatever has been captured so far into a WAV blob. */
  finishTake(endReason: CaptureEndReason): CaptureResult {
    this.recording = false;
    this.onAutoStop = null;
    const total = new Float32Array(this.sampleCount);
    let offset = 0;
    for (const chunk of this.chunks) {
      total.set(chunk, offset);
      offset += chunk.length;
    }
    this.chunks = [];

    const durationSec = total.length / this.sampleRate;
    const rms = this.takeSampleTotal > 0 ? Math.sqrt(this.takeSumSquares / this.takeSampleTotal) : 0;
    const blob = encodeWavPCM16(total, this.sampleRate);
    return {
      blob,
      durationSec,
      sampleRate: this.sampleRate,
      endReason,
      clipped: this.takePeak >= 0.98,
      peak: this.takePeak,
      rms,
    };
  }

  dispose(): void {
    this.workletNode?.port.close();
    this.workletNode?.disconnect();
    this.stream?.getTracks().forEach((t) => t.stop());
    void this.audioContext?.close();
    this.audioContext = null;
    this.stream = null;
    this.workletNode = null;
  }

  private handleBatch(batch: Float32Array): void {
    // Live level metering runs whenever the mic is open (mic-check screen too), independent of
    // whether a take is actively being recorded.
    let peak = 0;
    let sumSq = 0;
    for (let i = 0; i < batch.length; i++) {
      const v = Math.abs(batch[i]);
      if (v > peak) peak = v;
      sumSq += batch[i] * batch[i];
    }
    this.onLevel?.({ rms: Math.sqrt(sumSq / batch.length), peak });

    if (!this.recording) return;

    this.chunks.push(batch);
    this.sampleCount += batch.length;
    if (peak > this.takePeak) this.takePeak = peak;
    this.takeSumSquares += sumSq;
    this.takeSampleTotal += batch.length;

    if (this.sampleCount >= this.maxFrames) {
      this.recording = false;
      this.onAutoStop?.();
      return;
    }

    // Quiet-gap tracking, windowed at WINDOW_SEC so a single quiet sample can't flip the streak.
    this.windowSumSquares += sumSq;
    this.windowSampleCount += batch.length;
    if (this.windowSampleCount >= this.windowFrames) {
      const windowRMS = Math.sqrt(this.windowSumSquares / this.windowSampleCount);
      if (windowRMS < QUIET_RMS_THRESHOLD) {
        this.quietStreakFrames += this.windowSampleCount;
      } else {
        this.quietStreakFrames = 0;
      }
      this.windowSumSquares = 0;
      this.windowSampleCount = 0;

      const quietEnough = this.quietStreakFrames >= QUIET_STREAK_SEC * this.sampleRate;
      if (this.sampleCount >= this.minFrames && quietEnough) {
        this.recording = false;
        this.onAutoStop?.();
      }
    }
  }
}
