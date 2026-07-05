import { useState } from "react";

interface Props {
  participantId: string;
  sessionId: string;
  totalTakes: number;
}

export function DoneScreen({ participantId, sessionId, totalTakes }: Props) {
  const [copied, setCopied] = useState(false);

  async function copyId() {
    try {
      await navigator.clipboard.writeText(participantId);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard access can be denied/unavailable — the ID is still selectable text on screen.
    }
  }

  return (
    <div className="screen">
      <div className="done-check">✓</div>
      <h1>Enrollment complete</h1>
      <p>
        Thank you — {totalTakes} takes were recorded and uploaded for session{" "}
        <span className="mono">{sessionId.slice(0, 8)}</span>.
      </p>

      <div className="id-box">
        <p className="id-box-label">Your participant ID — save this</p>
        <p className="mono id-box-value">{participantId}</p>
        <button className="secondary-button" onClick={copyId}>
          {copied ? "Copied" : "Copy ID"}
        </button>
        <p className="hint-text">
          This is the only way to identify your data later. If you ever want your recordings
          deleted, go to <span className="mono">/delete</span> on this site and enter this ID —
          no other proof of identity is required, so don't share it publicly.
        </p>
      </div>

      <p className="lede">You can close this tab. Nothing else is needed from you right now.</p>
    </div>
  );
}
