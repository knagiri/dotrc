package db

import (
	"database/sql"
	"fmt"
	"strings"
)

// execer is what MarkDone needs from its connection, satisfied by both *sql.DB
// and *sql.Tx so the hook can mark a session done inside the transaction that
// records its end.
type execer interface {
	Exec(string, ...any) (sql.Result, error)
	Query(string, ...any) (*sql.Rows, error)
}

// MarkDone declares the work of sessionID and of every session it delegated,
// transitively, done as of now, and reports how many sessions it changed.
//
// Descendants follow session_links: a child is linked by its 8-char short id,
// so it is matched on the prefix of its full id. The recursive CTE uses UNION,
// which discards rows it has already produced, so a cycle in the links ends
// the walk instead of looping. A session already done keeps its earlier
// done_at -- its first time is the one the GC ages -- but is still walked
// through, so a child left open under a done parent is caught. A session
// reopened (Reopen) and marked done again is aged from the new time, since
// the write only touches rows whose done_at is NULL.
//
// Only the work axis moves. A descendant whose process is still running is
// left running; stopping it is reconcile's job (see DoneButRunning).
func MarkDone(x execer, sessionID string, now int64) (int, error) {
	res, err := x.Exec(`
		WITH RECURSIVE tree(id) AS (
		  SELECT ?1
		  UNION
		  SELECT s.session_id
		  FROM tree t
		  JOIN session_links l ON l.parent_session_id = t.id
		  JOIN sessions s ON substr(s.session_id, 1, 8) = l.child_short
		)
		UPDATE sessions SET done_at = ?2
		WHERE done_at IS NULL AND session_id IN (SELECT id FROM tree)
	`, sessionID, now)
	if err != nil {
		return 0, fmt.Errorf("mark done: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("mark done: %w", err)
	}
	return int(n), nil
}

// Reopen takes back a done: it clears sessionID's done_at, and reports false
// when the session is not done (open already, or not in the ledger). It is
// the only thing that clears done_at -- no hook event does, a resume included.
//
// Unlike MarkDone it does not cascade. The delegates a done marked with it
// stay done: the session reopened is the one a human picked, and which of its
// delegates also deserve it back is theirs to say, one at a time.
func Reopen(x execer, sessionID string) (bool, error) {
	res, err := x.Exec(
		"UPDATE sessions SET done_at = NULL WHERE session_id = ? AND done_at IS NOT NULL",
		sessionID,
	)
	if err != nil {
		return false, fmt.Errorf("reopen: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("reopen: %w", err)
	}
	return n > 0, nil
}

// DoneRetentionSec is how long a done session is kept before the GC deletes
// it: the window in which it can still be reopened, and so how far back the
// picker's done list reaches.
const DoneRetentionSec = 7 * 24 * 3600

// ListDoneRows returns the sessions done within the last maxAgeSec, most
// recently done first -- the picker's done list, which a reopen picks from.
//
// They are not in the queue view, which is open sessions only, so the row is
// built here with what the list shows: EffectiveState is the pseudo state
// "done", and CreatedAt (the age column) and ActivityAt are done_at, so the
// age reads how long ago the session was marked done. No pane is carried: a
// done row is reopened, never switched to.
func ListDoneRows(conn *sql.DB, maxAgeSec int64) ([]Row, error) {
	rows, err := conn.Query(`
		SELECT session_id, cwd, transcript_path, config_dir, kind, memo, done_at
		FROM sessions
		WHERE done_at IS NOT NULL AND done_at >= unixepoch() - ?
		ORDER BY done_at DESC, session_id
	`, maxAgeSec)
	if err != nil {
		return nil, fmt.Errorf("list done: %w", err)
	}
	defer rows.Close()
	var out []Row
	for rows.Next() {
		r := Row{EffectiveState: StateDone, RawState: StateDone}
		if err := rows.Scan(&r.SessionID, &r.Cwd, &r.TranscriptPath, &r.ConfigDir, &r.Kind, &r.Memo, &r.CreatedAt); err != nil {
			return nil, err
		}
		r.ActivityAt = r.CreatedAt
		out = append(out, r)
	}
	return out, rows.Err()
}

// minPrefix is the shortest id prefix ResolveSessionID accepts: the 8 chars
// `claude --bg` prints and every message about a session uses.
const minPrefix = 8

// ResolveSessionID returns the one full session id that starts with prefix.
// It refuses a prefix shorter than 8 chars, and one that matches no session
// or more than one -- marking the wrong session done hides it from the list.
func ResolveSessionID(conn *sql.DB, prefix string) (string, error) {
	if len(prefix) < minPrefix {
		return "", fmt.Errorf("session id %q is shorter than %d chars", prefix, minPrefix)
	}
	rows, err := conn.Query(
		"SELECT session_id FROM sessions WHERE substr(session_id, 1, ?) = ? ORDER BY session_id LIMIT 2",
		len(prefix), prefix,
	)
	if err != nil {
		return "", fmt.Errorf("resolve session id: %w", err)
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return "", err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	switch len(ids) {
	case 0:
		return "", fmt.Errorf("no session in the ledger starts with %q", prefix)
	case 1:
		return ids[0], nil
	}
	return "", fmt.Errorf("session id %q is ambiguous (%s, ...): give more of it", prefix, strings.Join(ids, ", "))
}

// DoneButRunning returns the background sessions whose work is done but whose
// process the ledger still has running -- what a cascade leaves behind when it
// marks a running delegate done. A session reopened before reconcile gets to
// it is open again, so it drops out of this list and keeps running.
// Interactive sessions are not returned: their process is a REPL a human may
// be looking at, and ending it is theirs to do.
func DoneButRunning(conn *sql.DB) ([]LiveSession, error) {
	rows, err := conn.Query(`
		SELECT session_id, config_dir FROM sessions
		WHERE done_at IS NOT NULL AND terminated_at IS NULL AND kind = ?
		ORDER BY started_at, session_id
	`, KindBackground)
	if err != nil {
		return nil, fmt.Errorf("done but running: %w", err)
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

// GC deletes the sessions (and their events) whose work has been done for
// longer than maxAgeSec, and the delegation links older than that with no open
// session at either end. Until then a done session can be reopened (Reopen);
// after, it is gone for good.
//
// A gone session is never collected, however long ago its process ended: its
// work is still open, and deleting it is exactly the silent loss of WIP the
// work axis exists to prevent. A link is aged by its own created_at rather than
// by its child's row, because the child may never have written one.
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
			WHERE done_at IS NOT NULL AND done_at < unixepoch() - ?
		)
	`, maxAgeSec); err != nil {
		return fmt.Errorf("gc events: %w", err)
	}
	if _, err := tx.Exec(`
		DELETE FROM sessions
		WHERE done_at IS NOT NULL AND done_at < unixepoch() - ?
	`, maxAgeSec); err != nil {
		return fmt.Errorf("gc sessions: %w", err)
	}
	if _, err := tx.Exec(`
		DELETE FROM session_links
		WHERE created_at < unixepoch() - ?
		  AND parent_session_id NOT IN (SELECT session_id FROM sessions WHERE done_at IS NULL)
		  AND child_short NOT IN (SELECT substr(session_id, 1, 8) FROM sessions WHERE done_at IS NULL)
	`, maxAgeSec); err != nil {
		return fmt.Errorf("gc session_links: %w", err)
	}
	return tx.Commit()
}

// RunningDelegateCounts maps each session to how many of its delegates are
// still running with their work open -- the delegates that may yet send it a
// report. A delegate is matched by its 8-char short id, as session_links
// records it.
func RunningDelegateCounts(conn *sql.DB) (map[string]int, error) {
	rows, err := conn.Query(`
		SELECT l.parent_session_id, COUNT(*)
		FROM session_links l
		JOIN sessions s ON substr(s.session_id, 1, 8) = l.child_short
		WHERE s.done_at IS NULL AND s.terminated_at IS NULL
		GROUP BY l.parent_session_id
	`)
	if err != nil {
		return nil, fmt.Errorf("running delegates: %w", err)
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var id string
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			return nil, err
		}
		out[id] = n
	}
	return out, rows.Err()
}
