package db

import (
	"database/sql"
	"errors"
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

	// PriorState is the session's latest non-ended state. On a running row it
	// repeats RawState; on a gone row it is what separates "the host went down
	// mid-task" from "it had finished a turn", which decides both the gone
	// ordering and what the summary column says.
	PriorState sql.NullString

	// Kind is how the session was started (KindInteractive / KindBackground /
	// KindPrint). NULL is a row recorded before the column existed, read as
	// interactive.
	Kind sql.NullString

	// ParentSessionID is the full id of the session that delegated this one,
	// from session_links. NULL means no link was recorded -- not that the
	// parent is done or gone.
	ParentSessionID sql.NullString

	// Marked is the manual "waiting" mark (see ToggleMark), held until it is
	// toggled off. It changes the picker's icon and nothing else -- not the
	// state, the priority or the ordering.
	Marked bool

	// Memo and PinNote are the free-text annotations (see SetMemo, SetPin).
	// PinNote is only ever set while Marked is.
	Memo    sql.NullString
	PinNote sql.NullString
}

// Session kinds, as sessions.kind records them.
const (
	KindInteractive = "interactive"
	KindBackground  = "background"
	KindPrint       = "print"
)

// StateGone is the pseudo effective_state of an open session whose process has
// ended (terminated_at set). No hook writes it: the queue view derives it, and
// the session stays listed until its work is marked done.
const StateGone = "gone"

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
// default working + stale are excluded; with both flags set nothing is. Gone
// rows are always included: the work is open and waiting on a resume, which is
// what the default listing is for.
//
// It is the filter ListRows applies, exposed because the picker reads every
// row and applies it itself: a delegating parent is usually `working`, and the
// picker must still find it to hang the filtered-in children off it.
func (o ListOpts) Includes(effectiveState string) bool {
	if o.ShowWorking && o.ShowStale {
		return true
	}
	switch effectiveState {
	case "awaiting_approval", "idle_done", StateGone:
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
		       q.prior_state, l.parent_session_id, q.marked, q.kind, q.memo, q.pin_note
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

// LatestEvent returns the state and unix time of a session's latest ledger
// event, read from the same queue view ListRows uses. found is false when the
// view has no entry for the session.
func LatestEvent(conn *sql.DB, sessionID string) (state string, createdAt int64, found bool, err error) {
	err = conn.QueryRow(`SELECT raw_state, created_at FROM queue WHERE session_id = ?`, sessionID).Scan(&state, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, false, nil
	}
	if err != nil {
		return "", 0, false, fmt.Errorf("latest event: %w", err)
	}
	return state, createdAt, true, nil
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

// ToggleMark flips the manual "waiting" mark on an open session and reports
// whether it is now marked.
//
// The mark holds until it is toggled off: a session waiting on something
// outside it (a review, another person) still gets touched in the meantime --
// a nudge, a question -- and that must not lift it. A gone session can be
// marked too; it is open work like any other.
//
// The column stores the event id the mark was set at, which nothing reads
// beyond "is it set"; it is kept rather than turned into a flag so a database
// written by the earlier, lapsing mark migrates without a schema change.
//
// Toggling the mark off drops the pin's note and its PR watch with it (see
// SetPin, SetPinPR). Toggling off also drops any stop on the PR's delivery
// along with the watch.
//
// A done or unknown session is left alone and reports false.
func ToggleMark(conn *sql.DB, sessionID string) (bool, error) {
	var marked sql.NullBool
	err := conn.QueryRow(`
		UPDATE sessions
		SET waiting_event_id = CASE
		      WHEN waiting_event_id IS NOT NULL THEN NULL
		      ELSE COALESCE((SELECT MAX(id) FROM events WHERE session_id = ?1), 0)
		    END,
		    pin_note = CASE WHEN waiting_event_id IS NOT NULL THEN NULL ELSE pin_note END,
		    pin_pr = CASE WHEN waiting_event_id IS NOT NULL THEN NULL ELSE pin_pr END,
		    pin_cursor = CASE WHEN waiting_event_id IS NOT NULL THEN NULL ELSE pin_cursor END,
		    pin_seen_at = CASE WHEN waiting_event_id IS NOT NULL THEN NULL ELSE pin_seen_at END,
		    pin_delivered_at = CASE WHEN waiting_event_id IS NOT NULL THEN NULL ELSE pin_delivered_at END,
		    pin_delivered_upto = CASE WHEN waiting_event_id IS NOT NULL THEN NULL ELSE pin_delivered_upto END,
		    pin_failures = NULL, pin_halted_upto = NULL
		WHERE session_id = ?1 AND done_at IS NULL
		RETURNING waiting_event_id IS NOT NULL
	`, sessionID).Scan(&marked)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("toggle mark: %w", err)
	}
	return marked.Bool, nil
}

// OpenSessionIDs returns the ids of every session whose work is not done,
// running or gone -- the sessions still able to answer for their delegates.
func OpenSessionIDs(conn *sql.DB) ([]string, error) {
	rows, err := conn.Query("SELECT session_id FROM sessions WHERE done_at IS NULL ORDER BY session_id")
	if err != nil {
		return nil, fmt.Errorf("open sessions: %w", err)
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

// scanRows drains a query shaped like the column list ListRows selects, and
// closes it.
func scanRows(rows *sql.Rows) ([]Row, error) {
	defer rows.Close()
	var out []Row
	for rows.Next() {
		var r Row
		if err := rows.Scan(
			&r.SessionID, &r.TmuxPane, &r.Cwd, &r.TranscriptPath, &r.ConfigDir,
			&r.EventType, &r.RawState, &r.EffectiveState, &r.Payload, &r.CreatedAt, &r.Priority,
			&r.PriorState, &r.ParentSessionID, &r.Marked, &r.Kind, &r.Memo, &r.PinNote,
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

// TerminateSession marks a session's process gone (terminated_at + ForcedEnd
// event), matching the cleanup pattern in hook.forcedEndSiblings. It moves the
// process axis only: the work stays open and the session stays listed, as
// gone, until something explicit marks it done (MarkDone). The reconcile sweep
// is the only caller that decides to close a row: it does so from the live
// agent roster, which is authoritative, rather than from a failed tmux command.
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
