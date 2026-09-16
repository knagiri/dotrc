package db

import (
	"database/sql"
	"fmt"

	"github.com/knagiri/dotrc/src/claude-queue/internal/configdir"
)

// Row is one session as surfaced by the queue view.
type Row struct {
	SessionID      string
	TmuxPane       sql.NullString
	Cwd            sql.NullString
	TranscriptPath sql.NullString
	// ConfigDir is the CLAUDE_CONFIG_DIR the session runs under. NULL is a row
	// written before the column existed; ConfigDirOf reads that as the default.
	ConfigDir      sql.NullString
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

	// ParentSessionID is the full id of the session that delegated this one,
	// from session_links. NULL means no link was recorded -- not that the
	// parent is gone -- and is always NULL on the resumable rows, which the
	// picker lists flat.
	ParentSessionID sql.NullString
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

// Includes reports whether a row in effectiveState passes the filter. By
// default working + stale are excluded; with both flags set nothing is.
//
// It is the filter ListRows applies, exposed because the picker reads every
// row and applies it itself: a delegating parent is usually `working`, and the
// picker must still find it to hang the filtered-in children off it.
func (o ListOpts) Includes(effectiveState string) bool {
	if o.ShowWorking && o.ShowStale {
		return true
	}
	switch effectiveState {
	case "awaiting_approval", "idle_done":
		return true
	case "working":
		return o.ShowWorking
	case "stale":
		return o.ShowStale
	}
	return false
}

// ListRows returns rows sorted by priority ASC, created_at DESC, filtered by
// opts.Includes, each carrying its recorded delegation parent (if any).
func ListRows(conn *sql.DB, opts ListOpts) ([]Row, error) {
	rows, err := conn.Query(`
		SELECT q.session_id, q.tmux_pane, q.cwd, q.transcript_path, q.config_dir,
		       q.event_type, q.raw_state, q.effective_state, q.payload, q.created_at, q.priority,
		       NULL AS prior_state, l.parent_session_id
		FROM queue q
		LEFT JOIN session_links l ON l.child_short = substr(q.session_id, 1, 8)
		ORDER BY q.priority ASC, q.created_at DESC
	`)
	if err != nil {
		return nil, fmt.Errorf("list: %w", err)
	}
	all, err := scanRows(rows)
	if err != nil {
		return nil, err
	}
	var out []Row
	for _, r := range all {
		if opts.Includes(r.EffectiveState) {
			out = append(out, r)
		}
	}
	return out, nil
}

// LinkSession records that the session whose id starts with childShort was
// delegated by parentSessionID. Re-linking a child replaces its parent and
// restarts the GC clock.
func LinkSession(conn *sql.DB, childShort, parentSessionID string) error {
	if _, err := conn.Exec(`
		INSERT INTO session_links(child_short, parent_session_id) VALUES (?, ?)
		ON CONFLICT(child_short) DO UPDATE
		  SET parent_session_id = excluded.parent_session_id, created_at = unixepoch()
	`, childShort, parentSessionID); err != nil {
		return fmt.Errorf("link session: %w", err)
	}
	return nil
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
//
// tmux_pane is dropped rather than selected. The ledger never clears it -- the
// upsert COALESCEs it forward -- so on these rows it always names the pane of a
// process that has ended, and pane ids are a per-server counter that a fresh
// server restarts from %0, meaning the recorded id almost certainly resolves to
// an unrelated live pane after a reboot. The picker's last-resort fallback
// trusts a ledger pane when the roster cannot be read, on the grounds that an
// unreadable roster is not evidence the session ended; for a row selected by
// terminated_at that premise is simply false, and honouring it would switch to
// a stranger's pane instead of resuming, silently. Where a pane is genuinely
// reachable the roster names the process and the picker re-derives the pane
// from its ancestry, so nothing is lost by withholding this column.
func ResumableCandidates(conn *sql.DB) ([]Row, error) {
	rows, err := conn.Query(`
		SELECT s.session_id, NULL AS tmux_pane, s.cwd, s.transcript_path, s.config_dir,
		       e.event_type, e.state AS raw_state, ? AS effective_state,
		       e.payload, e.created_at,
		       CASE WHEN p.state IN ('working', 'awaiting_approval') THEN ? ELSE ? END AS priority,
		       p.state AS prior_state, NULL AS parent_session_id
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
			&r.SessionID, &r.TmuxPane, &r.Cwd, &r.TranscriptPath, &r.ConfigDir,
			&r.EventType, &r.RawState, &r.EffectiveState, &r.Payload, &r.CreatedAt, &r.Priority,
			&r.PriorState, &r.ParentSessionID,
		); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// LiveSession is one row the ledger still considers running, paired with the
// config dir whose roster can confirm or deny that.
type LiveSession struct {
	SessionID string
	ConfigDir string
}

// LiveSessions returns the sessions the ledger still considers running, i.e.
// every row that never got a terminated_at, each with its config dir resolved.
// Ordered oldest first so a reconcile pass reports in a stable order.
//
// The dir rides along rather than being looked up per row because it decides
// WHICH roster the row is checked against: matching a session from one config
// dir against another dir's roster finds nothing, and "not in the roster" is
// precisely the signal that closes a row.
func LiveSessions(conn *sql.DB) ([]LiveSession, error) {
	rows, err := conn.Query(
		"SELECT session_id, config_dir FROM sessions WHERE terminated_at IS NULL ORDER BY started_at, session_id",
	)
	if err != nil {
		return nil, fmt.Errorf("live sessions: %w", err)
	}
	defer rows.Close()
	var out []LiveSession
	for rows.Next() {
		var id string
		var dir sql.NullString
		if err := rows.Scan(&id, &dir); err != nil {
			return nil, err
		}
		out = append(out, LiveSession{SessionID: id, ConfigDir: ConfigDirOf(dir)})
	}
	return out, rows.Err()
}

// ConfigDirOf unwraps a nullable config_dir into the dir a caller should use.
// NULL -- every row written before the column existed -- reads as the default,
// which is what those sessions ran under unless they set the env, and the env is
// what the column was added to stop guessing about going forward.
func ConfigDirOf(v sql.NullString) string {
	if v.Valid && v.String != "" {
		return v.String
	}
	return configdir.Default()
}

// RecordedConfigDirs returns the distinct non-empty config dirs the ledger
// holds, live rows and ended ones alike. Callers pass it through
// configdir.Union to get the list of dirs to consult.
//
// Ended rows count because a tool can be asked about a day, or a session, that
// is already over -- and because the ledger is the only place the set of dirs in
// use is written down at all.
func RecordedConfigDirs(conn *sql.DB) ([]string, error) {
	rows, err := conn.Query(
		"SELECT DISTINCT config_dir FROM sessions WHERE config_dir IS NOT NULL AND config_dir != '' ORDER BY config_dir",
	)
	if err != nil {
		return nil, fmt.Errorf("recorded config dirs: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var dir string
		if err := rows.Scan(&dir); err != nil {
			return nil, err
		}
		out = append(out, dir)
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
// older than maxAgeSec seconds ago, and the delegation links older than that
// whose child is no longer running. A link is aged by its own created_at
// rather than by its child's row, because the child may never have written
// one.
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
	if _, err := tx.Exec(`
		DELETE FROM session_links
		WHERE created_at < unixepoch() - ?
		  AND child_short NOT IN (SELECT substr(session_id, 1, 8) FROM sessions WHERE terminated_at IS NULL)
	`, maxAgeSec); err != nil {
		return fmt.Errorf("gc session_links: %w", err)
	}
	return tx.Commit()
}
