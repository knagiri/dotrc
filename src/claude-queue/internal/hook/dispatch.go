package hook

import (
	"database/sql"
	"encoding/json"
	"fmt"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/state"
)

// Deps bundles the dependencies a hook invocation needs.
type Deps struct {
	DB   *sql.DB
	Pane string // tmux pane id, may be empty
}

// Dispatch applies the state transition for the given event.
// Unknown events are ignored (no-op, no error). Always safe to call
// from a Claude Code hook — callers should swallow errors and exit 0.
func Dispatch(d *Deps, event string, in *Input) error {
	target, ok := state.ForEvent(event)
	if !ok {
		return nil // silently drop unknown events
	}

	tx, err := d.DB.Begin()
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()

	if event == "SessionStart" {
		if err := upsertSession(tx, in, d.Pane); err != nil {
			return err
		}
		if d.Pane != "" {
			if err := forcedEndSiblings(tx, in.SessionID, d.Pane); err != nil {
				return err
			}
		}
	} else {
		// For non-SessionStart events, ensure the session row exists
		// so the foreign key constraint holds (defensive against
		// missing SessionStart, e.g. hook registration mid-session).
		if err := ensureSession(tx, in); err != nil {
			return err
		}
	}

	if event == "SessionEnd" {
		if _, err := tx.Exec(
			"UPDATE sessions SET terminated_at = unixepoch() WHERE session_id = ?",
			in.SessionID,
		); err != nil {
			return fmt.Errorf("set terminated_at: %w", err)
		}
	}

	payload := buildPayload(event, in)
	if _, err := tx.Exec(
		"INSERT INTO events(session_id, event_type, state, payload) VALUES (?, ?, ?, ?)",
		in.SessionID, event, target, payload,
	); err != nil {
		return fmt.Errorf("insert event: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return err
	}
	if event == "SessionEnd" {
		// Best-effort: don't fail the hook on gc errors.
		_ = db.GC(d.DB, 7*24*3600)
	}
	return nil
}

func upsertSession(tx *sql.Tx, in *Input, pane string) error {
	var paneVal interface{}
	if pane != "" {
		paneVal = pane
	}
	_, err := tx.Exec(`
		INSERT INTO sessions(session_id, tmux_pane, cwd, transcript_path)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(session_id) DO UPDATE SET
			tmux_pane       = COALESCE(excluded.tmux_pane, sessions.tmux_pane),
			cwd             = COALESCE(excluded.cwd, sessions.cwd),
			transcript_path = COALESCE(excluded.transcript_path, sessions.transcript_path)
	`, in.SessionID, paneVal, nullIfEmpty(in.Cwd), nullIfEmpty(in.TranscriptPath))
	if err != nil {
		return fmt.Errorf("upsert session: %w", err)
	}
	return nil
}

func ensureSession(tx *sql.Tx, in *Input) error {
	_, err := tx.Exec(`
		INSERT INTO sessions(session_id, cwd, transcript_path)
		VALUES (?, ?, ?)
		ON CONFLICT(session_id) DO NOTHING
	`, in.SessionID, nullIfEmpty(in.Cwd), nullIfEmpty(in.TranscriptPath))
	if err != nil {
		return fmt.Errorf("ensure session: %w", err)
	}
	return nil
}

func forcedEndSiblings(tx *sql.Tx, newID, pane string) error {
	rows, err := tx.Query(`
		SELECT session_id FROM sessions
		WHERE tmux_pane = ? AND session_id != ? AND terminated_at IS NULL
	`, pane, newID)
	if err != nil {
		return fmt.Errorf("find siblings: %w", err)
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id)
	}
	rows.Close()

	for _, id := range ids {
		if _, err := tx.Exec(
			"UPDATE sessions SET terminated_at = unixepoch() WHERE session_id = ?", id,
		); err != nil {
			return fmt.Errorf("terminate sibling %s: %w", id, err)
		}
		if _, err := tx.Exec(
			"INSERT INTO events(session_id, event_type, state) VALUES (?, 'ForcedEnd', 'ended')", id,
		); err != nil {
			return fmt.Errorf("insert ForcedEnd %s: %w", id, err)
		}
	}
	return nil
}

func nullIfEmpty(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

// buildPayload returns the JSON payload to persist for the event, or "".
func buildPayload(event string, in *Input) string {
	p := map[string]interface{}{}
	switch event {
	case "SessionStart":
		if in.Source != "" {
			p["source"] = in.Source
		}
	case "PermissionRequest", "PermissionDenied", "PostToolUse", "PostToolUseFailure":
		if in.ToolName != "" {
			p["tool_name"] = in.ToolName
		}
		if len(in.ToolInput) > 0 {
			p["tool_input"] = json.RawMessage(in.ToolInput)
		}
		if in.Error != "" {
			p["error"] = in.Error
		}
	case "Stop":
		if in.LastAssistantMessage != "" {
			p["last_assistant_message"] = in.LastAssistantMessage
		}
	case "StopFailure":
		if in.Error != "" {
			p["error"] = in.Error
		}
	case "SessionEnd":
		if in.Reason != "" {
			p["reason"] = in.Reason
		}
	}
	if len(p) == 0 {
		return ""
	}
	b, err := json.Marshal(p)
	if err != nil {
		return ""
	}
	return string(b)
}
