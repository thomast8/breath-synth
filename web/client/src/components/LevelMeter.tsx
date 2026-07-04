interface Props {
  rms: number;
  active: boolean;
}

export function LevelMeter({ rms, active }: Props) {
  // Scaled against the quiet-gap threshold rather than a fixed absolute amplitude, so gentle calm
  // breathing and a loud forced exhale both read as meaningfully non-empty.
  const fraction = Math.min(1, rms / 0.08);
  return (
    <div className="level-meter" role="meter" aria-label="Microphone level" aria-valuenow={fraction}>
      <div
        className={`level-meter-fill ${active ? "active" : ""}`}
        style={{ width: `${fraction * 100}%` }}
      />
    </div>
  );
}
