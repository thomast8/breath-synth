interface Props {
  sessionId: string;
  totalTakes: number;
}

export function DoneScreen({ sessionId, totalTakes }: Props) {
  return (
    <div className="screen">
      <div className="done-check">✓</div>
      <h1>Enrollment complete</h1>
      <p>
        Thank you — {totalTakes} takes were recorded and uploaded for session{" "}
        <span className="mono">{sessionId.slice(0, 8)}</span>.
      </p>
      <p className="lede">You can close this tab. Nothing else is needed from you right now.</p>
    </div>
  );
}
