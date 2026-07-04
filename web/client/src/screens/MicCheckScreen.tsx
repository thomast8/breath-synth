import { useState } from "react";
import { LevelMeter } from "../components/LevelMeter";
import type { CaptureController } from "../audio/CaptureController";

const ROOM_TONE_SECONDS = 5;

interface Props {
  capture: CaptureController;
  level: { rms: number; peak: number };
  micReady: boolean;
  micError: string | null;
  onReady: (roomTone: Blob, sampleRate: number) => void;
  error: string | null;
  uploading: boolean;
}

/** Mic permission + a brief guided-silence room-tone capture — a dedicated step rather than the
 * native app's incremental per-take harvesting, since the server grades against one uploaded
 * room-tone clip per session (see SessionsController.uploadRoomTone) rather than an accumulating
 * pool. Simpler to implement correctly and only costs the participant a few seconds up front. */
export function MicCheckScreen({ capture, level, micReady, micError, onReady, error, uploading }: Props) {
  const [recordingRoomTone, setRecordingRoomTone] = useState(false);
  const [countdown, setCountdown] = useState(ROOM_TONE_SECONDS);

  function startRoomTone() {
    setRecordingRoomTone(true);
    setCountdown(ROOM_TONE_SECONDS);
    const interval = setInterval(() => {
      setCountdown((c) => Math.max(0, c - 1));
    }, 1000);
    capture.startTake(ROOM_TONE_SECONDS, ROOM_TONE_SECONDS + 2, () => {
      clearInterval(interval);
      const result = capture.finishTake("auto");
      onReady(result.blob, result.sampleRate);
    });
  }

  const noiseSuppressionOn =
    capture.actualSettings?.noiseSuppression === true ||
    capture.actualSettings?.echoCancellation === true ||
    capture.actualSettings?.autoGainControl === true;

  return (
    <div className="screen">
      <h1>Mic check</h1>
      {micError && (
        <p className="error-text">
          Couldn't access the microphone: {micError}. Check your browser's permission settings and
          reload.
        </p>
      )}
      {!micError && !micReady && <p>Requesting microphone access…</p>}
      {micReady && !recordingRoomTone && (
        <>
          <p>Speak or breathe normally to check the level, then record a few seconds of silence.</p>
          <LevelMeter rms={level.rms} active={micReady} />
          {noiseSuppressionOn && (
            <p className="warning-text">
              This browser may be applying noise suppression or auto-gain to the mic input, which
              can mask quiet breath sounds. Chrome or Firefox on desktop usually honor the request
              to disable it; this is logged either way.
            </p>
          )}
          <button className="primary-button" onClick={startRoomTone}>
            Record room tone ({ROOM_TONE_SECONDS}s of quiet)
          </button>
        </>
      )}
      {recordingRoomTone && (
        <div className="capture-status">
          <p>Stay quiet… {countdown}s</p>
          <LevelMeter rms={level.rms} active />
        </div>
      )}
      {uploading && <p>Uploading room tone…</p>}
      {error && <p className="error-text">{error}</p>}
    </div>
  );
}
