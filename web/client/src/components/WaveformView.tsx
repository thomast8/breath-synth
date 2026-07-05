import { useEffect, useRef } from "react";
import type { WavePeak } from "../audio/StreamingCapture";

interface Props {
  peaks: WavePeak[];
}

/** Client-only scrolling waveform, built from `StreamingCapture`'s pre-send samples — the server
 * deliberately never sends raw audio back (`TakeCaptureEngine` drops its own `wavePeaks` tracking on
 * purpose), so this mirrors native `EnrollWaveformView` using only what the browser already has. */
export function WaveformView({ peaks }: Props) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return;
    const { width, height } = canvas;
    ctx.clearRect(0, 0, width, height);
    if (peaks.length === 0) return;

    const midY = height / 2;
    const barWidth = width / peaks.length;
    ctx.fillStyle = getComputedStyle(canvas).color || "#2f7a63";
    peaks.forEach((peak, i) => {
      const x = i * barWidth;
      const yTop = midY - peak.max * midY;
      const yBottom = midY - peak.min * midY;
      ctx.fillRect(x, yTop, Math.max(1, barWidth - 1), Math.max(1, yBottom - yTop));
    });
  }, [peaks]);

  return <canvas ref={canvasRef} className="waveform-view" width={320} height={64} />;
}
