import { LevelMeter } from "../components/LevelMeter";
import type { StreamingCapture } from "../audio/StreamingCapture";

interface Props {
  capture: StreamingCapture;
  level: { rms: number; peak: number };
  micReady: boolean;
  micError: string | null;
  connecting: boolean;
  error: string | null;
  onContinue: () => void;
  onRequestStartOver: () => void;
}

/** Mic permission + level sanity only — room tone is no longer a dedicated step. It harvests
 * silently server-side during the first technique steps, exactly like the native app's ambient
 * pool, so there is nothing to record or upload here. */
export function MicCheckScreen({
  capture,
  level,
  micReady,
  micError,
  connecting,
  error,
  onContinue,
  onRequestStartOver,
}: Props) {
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
      {micReady && (
        <>
          <p>Speak or breathe normally to check the level.</p>
          <LevelMeter level={level.rms} active={micReady} />
          {noiseSuppressionOn && (
            <p className="warning-text">
              This browser may be applying noise suppression or auto-gain to the mic input, which
              can mask quiet breath sounds. Chrome or Firefox on desktop usually honor the request
              to disable it; this is logged either way.
            </p>
          )}
          {error && (
            <p className="error-text">
              Couldn't connect to the server: {error} Check your connection and try again.
            </p>
          )}
          <button className="primary-button" disabled={connecting} onClick={onContinue}>
            {connecting ? "Connecting…" : "Continue"}
          </button>
          <p className="hint-text">
            Your progress saves automatically as you go — it's safe to close this tab and come back
            later.
          </p>
        </>
      )}
      <button className="link-button" onClick={onRequestStartOver}>
        Start over
      </button>
    </div>
  );
}
