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
}

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
		       event_type, raw_state, effective_state, payload, created_at, priority
		FROM queue
		WHERE %s
		ORDER BY priority ASC, created_at DESC
	`, where[0])

	rows, err := conn.Query(q)
	if err != nil {
		return nil, fmt.Errorf("list: %w", err)
	}
	defer rows.Close()

	var out []Row
	for rows.Next() {
		var r Row
		if err := rows.Scan(
			&r.SessionID, &r.TmuxPane, &r.Cwd, &r.TranscriptPath,
			&r.EventType, &r.RawState, &r.EffectiveState, &r.Payload, &r.CreatedAt, &r.Priority,
		); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
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
