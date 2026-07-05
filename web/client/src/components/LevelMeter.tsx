interface Props {
  level: number;
  /** What counts as "full" on the bar. Defaults to a fixed cosmetic value for contexts with no
   * server-reported threshold yet (mic-check, pre-arm); once a step is armed, pass the server's
   * own `detectionState.activityThreshold` so the bar reads in the same units the engine is
   * actually gating on. */
  threshold?: number;
  active: boolean;
}

export function LevelMeter({ level, threshold = 0.08, active }: Props) {
  const fraction = Math.min(1, level / threshold);
  return (
    <div className="level-meter" role="meter" aria-label="Microphone level" aria-valuenow={fraction}>
      <div
        className={`level-meter-fill ${active ? "active" : ""}`}
        style={{ width: `${fraction * 100}%` }}
      />
    </div>
  );
}
