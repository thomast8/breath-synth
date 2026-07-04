import { useState } from "react";
import type { ExperienceLevel } from "../api/types";

const CONSENT_VERSION = "2026-07-01";

interface Props {
  requiresInviteCode: boolean;
  onSubmit: (fields: {
    inviteCode: string | null;
    pseudonym: string | null;
    experienceLevel: ExperienceLevel;
    consentVersion: string;
  }) => void;
  error: string | null;
  submitting: boolean;
}

export function ConsentScreen({ requiresInviteCode, onSubmit, error, submitting }: Props) {
  const [inviteCode, setInviteCode] = useState("");
  const [pseudonym, setPseudonym] = useState("");
  const [experienceLevel, setExperienceLevel] = useState<ExperienceLevel>("intermediate");
  const [agreed, setAgreed] = useState(false);

  const canSubmit = agreed && (!requiresInviteCode || inviteCode.trim().length > 0) && !submitting;

  return (
    <div className="screen">
      <h1>Breath Enroll</h1>
      <p className="lede">
        Thanks for helping build a training dataset for freediving breath techniques. This app
        walks you through a short guided recording session — calm breathing, FRC/RV exhales,
        packing, and recovery hooks — and uploads the audio for research and future model
        training. No video, no location, and you can stop at any point.
      </p>

      {requiresInviteCode && (
        <label className="field">
          Invite code
          <input
            value={inviteCode}
            onChange={(e) => setInviteCode(e.target.value)}
            autoComplete="off"
            placeholder="Given to you by whoever invited you"
          />
        </label>
      )}

      <label className="field">
        Pseudonym (optional)
        <input
          value={pseudonym}
          onChange={(e) => setPseudonym(e.target.value)}
          placeholder="A nickname, not your real name"
        />
      </label>

      <label className="field">
        Freediving experience
        <select
          value={experienceLevel}
          onChange={(e) => setExperienceLevel(e.target.value as ExperienceLevel)}
        >
          <option value="novice">Novice</option>
          <option value="intermediate">Intermediate</option>
          <option value="advanced">Advanced</option>
          <option value="instructor">Instructor</option>
        </select>
      </label>

      <label className="checkbox-field">
        <input type="checkbox" checked={agreed} onChange={(e) => setAgreed(e.target.checked)} />
        I agree that my recorded breath audio and the details above can be used for research and
        to train future models, and I can request deletion at any time.
      </label>

      {error && <p className="error-text">{error}</p>}

      <button
        className="primary-button"
        disabled={!canSubmit}
        onClick={() =>
          onSubmit({
            inviteCode: requiresInviteCode ? inviteCode.trim() : null,
            pseudonym: pseudonym.trim() || null,
            experienceLevel,
            consentVersion: CONSENT_VERSION,
          })
        }
      >
        {submitting ? "Starting…" : "Start enrollment"}
      </button>
    </div>
  );
}
