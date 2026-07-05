import { useState } from "react";
import { deleteParticipant, ApiError } from "../api/client";

type Status = "idle" | "confirming" | "deleting" | "done" | "error";

/** Self-serve deletion, reachable at `/delete` — the participant's own ID (shown once, on the done
 * screen) is the sole proof required. Deliberately a two-step confirm (not a single click) since
 * this is irreversible: recordings, take rows, and the participant record are gone server-side. */
export function DeleteDataScreen() {
  const [id, setId] = useState("");
  const [status, setStatus] = useState<Status>("idle");
  const [error, setError] = useState<string | null>(null);

  async function confirmDelete() {
    setStatus("deleting");
    setError(null);
    try {
      await deleteParticipant(id.trim());
      setStatus("done");
    } catch (e) {
      setStatus("error");
      if (e instanceof ApiError && e.status === 404) {
        setError("No participant found with that ID — double-check it was copied correctly.");
      } else {
        setError(e instanceof Error ? e.message : String(e));
      }
    }
  }

  if (status === "done") {
    return (
      <div className="screen">
        <div className="done-check">✓</div>
        <h1>Data deleted</h1>
        <p>
          Your participant record, sessions, recorded takes, and stored audio have all been
          removed. This can't be undone.
        </p>
      </div>
    );
  }

  return (
    <div className="screen">
      <h1>Delete my data</h1>
      <p className="lede">
        Enter the participant ID you were shown at the end of enrollment. This permanently deletes
        your participant record, every session, every recorded take, and the underlying audio
        files — there is no undo.
      </p>

      <label className="field">
        Participant ID
        <input
          value={id}
          onChange={(e) => {
            setId(e.target.value);
            setStatus("idle");
            setError(null);
          }}
          autoComplete="off"
          placeholder="Paste the ID from your done screen"
        />
      </label>

      {error && <p className="error-text">{error}</p>}

      {status !== "confirming" && (
        <button
          className="primary-button"
          disabled={id.trim().length === 0}
          onClick={() => setStatus("confirming")}
        >
          Delete my data
        </button>
      )}

      {status === "confirming" && (
        <div className="capture-status">
          <p className="warning-text">
            This can't be undone. Delete everything for participant{" "}
            <span className="mono">{id.trim()}</span>?
          </p>
          <button className="primary-button" onClick={confirmDelete}>
            Yes, permanently delete
          </button>
          <button className="secondary-button" onClick={() => setStatus("idle")}>
            Cancel
          </button>
        </div>
      )}

      {status === "deleting" && <p>Deleting…</p>}
    </div>
  );
}
