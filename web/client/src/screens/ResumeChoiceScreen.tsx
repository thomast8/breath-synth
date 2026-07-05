interface Props {
  onResume: () => void;
  onStartOver: () => void;
}

/** Shown once, on load, only when localStorage has a saved participant/session — an explicit choice
 * instead of silently auto-resuming, since a silent jump straight past consent could be surprising
 * to someone who actually meant to start fresh (different person on a shared machine, a much later
 * revisit, etc.). */
export function ResumeChoiceScreen({ onResume, onStartOver }: Props) {
  return (
    <div className="screen">
      <h1>Welcome back</h1>
      <p className="lede">
        You have an enrollment in progress on this browser. Continue where you left off, or start a
        new one?
      </p>
      <button className="primary-button" onClick={onResume}>
        Continue where I left off
      </button>
      <button className="secondary-button" onClick={onStartOver}>
        Start a new enrollment instead
      </button>
    </div>
  );
}
