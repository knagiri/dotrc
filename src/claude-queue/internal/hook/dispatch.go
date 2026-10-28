package hook

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/state"
)

// Deps bundles the dependencies a hook invocation needs.
type Deps struct {
	DB   *sql.DB
	Pane string // tmux pane id, may be empty
	// ConfigDir is the CLAUDE_CONFIG_DIR this session runs under, resolved by
	// Run (see configdir.Resolve). Empty leaves the column as it was, which is
	// what keeps a caller that cannot tell from overwriting a recorded dir with
	// a guess.
	ConfigDir string
	// Kind is how the session was started (db.KindInteractive / KindBackground
	// / KindPrint), resolved by Run from the environment (see KindFromEnv).
	// Empty leaves the column as it was.
	Kind string
}

// doneReasons are the SessionEnd reasons that mean a human ended the work, not
// just the process: leaving the REPL (Ctrl-C, /exit) and /clear, after which
// the next task starts in a new session. Every other reason -- "other" covers
// `claude stop`, a killed pane and a host shutdown alike -- only ends the
// process, and the session stays open as gone.
var doneReasons = map[string]bool{
	"prompt_input_exit": true,
	"clear":             true,
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

	// Upsert on every event: when SessionStart hook is dropped (e.g.
	// /resume, hook registered mid-session) later events still need to
	// populate tmux_pane so the picker can switch to the live pane.
	now := time.Now().Unix()
	if err := upsertSession(tx, in, d.Pane, d.ConfigDir, d.Kind); err != nil {
		return err
	}
	if event == "SessionStart" && d.Pane != "" {
		// A /clear replaces the pane's session with a new one for the next
		// task, so the one it replaces is done. Any other new session in the
		// pane only shows the old process is gone.
		if err := forcedEndSiblings(tx, in.SessionID, d.Pane, in.Source == "clear", now); err != nil {
			return err
		}
	}

	// Must stay after upsertSession, which clears terminated_at on every event
	// (see its doc comment). Same transaction, so the order alone decides whether
	// a SessionEnd leaves the row closed.
	if event == "SessionEnd" {
		if _, err := tx.Exec(
			"UPDATE sessions SET terminated_at = unixepoch() WHERE session_id = ?",
			in.SessionID,
		); err != nil {
			return fmt.Errorf("set terminated_at: %w", err)
		}
		// A print-mode run is one-shot: there is no WIP to come back to, so its
		// end is always the end of its work, whatever the reason says.
		if doneReasons[in.Reason] || d.Kind == db.KindPrint {
			if _, err := db.MarkDone(tx, in.SessionID, now); err != nil {
				return err
			}
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
		_ = db.GC(d.DB, db.DoneRetentionSec)
	}
	return nil
}

// upsertSession creates or refreshes the session row.
//
// terminated_at is cleared on EVERY event, not just SessionStart: a live hook
// event is itself the disproof of a recorded end. `claude --resume <uuid>` keeps
// the session id, so without this a session that ended once would stay gone
// forever, though its process is running again.
//
// done_at is never touched: only an explicit reopen (db.Reopen) takes a done
// back, so a done session that is resumed stays out of the listing. kind is overwritten when known, since a
// resume can bring a session back as another kind (`claude --bg --resume`).
//
// Dispatch relies on running this BEFORE it re-sets terminated_at for SessionEnd
// -- both happen in the same transaction, so a genuine end still lands closed.
func upsertSession(tx *sql.Tx, in *Input, pane, cfgDir, kind string) error {
	var paneVal interface{}
	if pane != "" {
		paneVal = pane
	}
	_, err := tx.Exec(`
		INSERT INTO sessions(session_id, tmux_pane, cwd, transcript_path, config_dir, kind)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(session_id) DO UPDATE SET
			tmux_pane       = COALESCE(excluded.tmux_pane, sessions.tmux_pane),
			cwd             = COALESCE(excluded.cwd, sessions.cwd),
			transcript_path = COALESCE(excluded.transcript_path, sessions.transcript_path),
			config_dir      = COALESCE(excluded.config_dir, sessions.config_dir),
			kind            = COALESCE(excluded.kind, sessions.kind),
			terminated_at   = NULL
	`, in.SessionID, paneVal, nullIfEmpty(in.Cwd), nullIfEmpty(in.TranscriptPath), nullIfEmpty(cfgDir), nullIfEmpty(kind))
	if err != nil {
		return fmt.Errorf("upsert session: %w", err)
	}
	return nil
}

// forcedEndSiblings marks gone every other running session recorded on pane:
// a new session starting there means the old process is no longer in it. With
// markDone (the new session came from /clear) their work is done as well.
func forcedEndSiblings(tx *sql.Tx, newID, pane string, markDone bool, now int64) error {
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
		if markDone {
			if _, err := db.MarkDone(tx, id, now); err != nil {
				return err
			}
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
