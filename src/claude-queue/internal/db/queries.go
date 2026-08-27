package db

import (
	"database/sql"
	"fmt"
)

// Row is one session as surfaced by the queue view.
type Row struct {
	SessionID      string
	TmuxPane       sql.NullString
	Cwd            sql.NullString
	TranscriptPath sql.NullString
	EventType      string
	RawState       string
	EffectiveState string
	Payload        sql.NullString
	CreatedAt      int64
	Priority       int

	// PriorState is the state the session was last in before it ended, and is
	// set only for the resumable rows -- a live row's own RawState already says
	// what it is doing. It is what separates "the host went down mid-task" from
	// "the work was finished and the session closed", which decides both the
	// resumable ordering and what the summary column says.
	PriorState sql.NullString
}

// StateResumable is the pseudo effective_state of a terminated row that
// `claude --resume` can reopen. It is not a state any hook writes: the ledger
// only knows 'ended', and this names the subset of ended rows worth offering.
const StateResumable = "resumable"

// priorityResumable / priorityResumableIdle sort the resumable rows behind
// every live one -- the queue view's own priorities top out at 5 -- and, among
// themselves, put the sessions that were interrupted mid-task first.
const (
	priorityResumable     = 6
	priorityResumableIdle = 7
)

// ListOpts filters the queue listing.
type ListOpts struct {
	ShowWorking bool
	ShowStale   bool
}

// Counts returns { effective_state: count } across the queue view.
func Counts(conn *sql.DB) (map[string]int, error) {
	rows, err := conn.Query(
		"SELECT effective_state, COUNT(*) FROM queue GROUP BY effective_state",
	)
	if err != nil {
		return nil, fmt.Errorf("counts: %w", err)
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var s string
		var n int
		if err := rows.Scan(&s, &n); err != nil {
			return nil, err
		}
		out[s] = n
	}
	return out, rows.Err()
}

// ListRows returns rows sorted by priority ASC, created_at DESC.
// By default working + stale are excluded.
func ListRows(conn *sql.DB, opts ListOpts) ([]Row, error) {
	where := []string{"effective_state IN ('awaiting_approval', 'idle_done')"}
	if opts.ShowWorking {
		where[0] = "effective_state IN ('awaiting_approval', 'idle_done', 'working')"
	}
	if opts.ShowStale {
		if opts.ShowWorking {
			where[0] = "1=1"
		} else {
			where[0] = "effective_state IN ('awaiting_approval', 'idle_done', 'stale')"
		}
	}
	q := fmt.Sprintf(`
		SELECT session_id, tmux_pane, cwd, transcript_path,
		       event_type, raw_state, effective_state, payload, created_at, priority,
		       NULL AS prior_state
		FROM queue
		WHERE %s
		ORDER BY priority ASC, created_at DESC
	`, where[0])

	rows, err := conn.Query(q)
	if err != nil {
		return nil, fmt.Errorf("list: %w", err)
	}
	return scanRows(rows)
}

// ResumableCandidates returns the terminated rows whose conversation
// `claude --resume` could reopen, ordered to follow the live rows: interrupted
// sessions first, newest first within each group.
//
// This is only the half of the test that SQL can answer. A resume also needs
// the transcript and the working directory to still be on disk, and the ledger
// having recorded a path is no evidence of that -- short-lived sessions never
// write a jsonl, and a reaped worktree takes the cwd with it. Callers must run
// the surviving candidates past a filesystem check (picker.filterResumable)
// before offering them, because `claude --resume` with an id it cannot find
// starts an empty session under that id instead of failing.
//
// The reason filter is what keeps the list to sessions that were CUT OFF. A
// SessionEnd carrying reason 'prompt_input_exit' is a human closing the REPL at
// a stopping point, so it is excluded; every other end is either a signal
// (SIGTERM, `claude stop`, the host going down) or a ForcedEnd synthesised by
// reconcile after a session vanished without notice, and those are the ones
// worth offering back. json_valid guards the extract because a SessionEnd with
// no reason stores an empty payload string, which json_extract rejects as
// malformed rather than reading as absent.
func ResumableCandidates(conn *sql.DB) ([]Row, error) {
	rows, err := conn.Query(`
		SELECT s.session_id, s.tmux_pane, s.cwd, s.transcript_path,
		       e.event_type, e.state AS raw_state, ? AS effective_state,
		       e.payload, e.created_at,
		       CASE WHEN p.state IN ('working', 'awaiting_approval') THEN ? ELSE ? END AS priority,
		       p.state AS prior_state
		FROM events e
		JOIN (SELECT session_id, MAX(id) AS mid FROM events GROUP BY session_id) l
		  ON e.id = l.mid
		JOIN sessions s ON s.session_id = e.session_id
		LEFT JOIN events p ON p.id = (
		  SELECT MAX(id) FROM events
		  WHERE session_id = e.session_id AND id < e.id AND state != 'ended'
		)
		WHERE s.terminated_at IS NOT NULL
		  AND e.state = 'ended'
		  AND COALESCE(
		        CASE WHEN json_valid(e.payload) THEN json_extract(e.payload, '$.reason') END,
		        ''
		      ) != 'prompt_input_exit'
		ORDER BY priority ASC, e.created_at DESC
	`, StateResumable, priorityResumable, priorityResumableIdle)
	if err != nil {
		return nil, fmt.Errorf("list resumable: %w", err)
	}
	return scanRows(rows)
}

// scanRows drains a query shaped like the column list both listings select, and
// closes it. Shared so the two cannot drift apart in column order.
func scanRows(rows *sql.Rows) ([]Row, error) {
	defer rows.Close()
	var out []Row
	for rows.Next() {
		var r Row
		if err := rows.Scan(
			&r.SessionID, &r.TmuxPane, &r.Cwd, &r.TranscriptPath,
			&r.EventType, &r.RawState, &r.EffectiveState, &r.Payload, &r.CreatedAt, &r.Priority,
			&r.PriorState,
		); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// LiveSessionIDs returns the session ids the ledger still considers running,
// i.e. every row that never got a terminated_at. Ordered oldest first so a
// reconcile pass reports in a stable order.
func LiveSessionIDs(conn *sql.DB) ([]string, error) {
	rows, err := conn.Query(
		"SELECT session_id FROM sessions WHERE terminated_at IS NULL ORDER BY started_at, session_id",
	)
	if err != nil {
		return nil, fmt.Errorf("live sessions: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// TerminateSession marks a session ended (terminated_at + ForcedEnd event),
// matching the cleanup pattern in hook.forcedEndSiblings. The reconcile sweep is
// the only caller that decides to close a row: it does so from the live agent
// roster, which is authoritative, rather than from a failed tmux command.
func TerminateSession(conn *sql.DB, sessionID string) error {
	tx, err := conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(
		"UPDATE sessions SET terminated_at = unixepoch() WHERE session_id = ?", sessionID,
	); err != nil {
		return fmt.Errorf("terminate session: %w", err)
	}
	if _, err := tx.Exec(
		"INSERT INTO events(session_id, event_type, state) VALUES (?, 'ForcedEnd', 'ended')", sessionID,
	); err != nil {
		return fmt.Errorf("insert ForcedEnd: %w", err)
	}
	return tx.Commit()
}

// GC deletes ended sessions (and their events) whose terminated_at is
// older than maxAgeSec seconds ago.
func GC(conn *sql.DB, maxAgeSec int64) error {
	tx, err := conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`
		DELETE FROM events
		WHERE session_id IN (
			SELECT session_id FROM sessions
			WHERE terminated_at IS NOT NULL AND terminated_at < unixepoch() - ?
		)
	`, maxAgeSec); err != nil {
		return fmt.Errorf("gc events: %w", err)
	}
	if _, err := tx.Exec(`
		DELETE FROM sessions
		WHERE terminated_at IS NOT NULL AND terminated_at < unixepoch() - ?
	`, maxAgeSec); err != nil {
		return fmt.Errorf("gc sessions: %w", err)
	}
	return tx.Commit()
}
