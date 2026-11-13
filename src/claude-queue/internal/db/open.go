package db

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// Open opens the SQLite database at path, applies PRAGMAs, schema and
// migrations. The returned *sql.DB is safe for concurrent use.
//
// Open runs concurrently with itself as a matter of course -- every hook event
// is its own process -- so each step must hold up against another process
// doing the same thing at the same moment. The PRAGMAs ride on the DSN, which
// sets them on every connection the pool opens (an Exec would reach only one)
// and sets busy_timeout before anything that can take a lock.
//
// The order of the remaining steps is load-bearing: Tables first so a fresh
// database has them, migrate() second so an existing one gains the columns
// CREATE TABLE IF NOT EXISTS cannot add, migrateLifecycle() and
// migratePRWatches() next because they read those columns, and the view last
// because it selects a column that only exists after the migration.
func Open(path string) (*sql.DB, error) {
	name, err := dsn(path)
	if err != nil {
		return nil, err
	}
	conn, err := sql.Open("sqlite", name)
	if err != nil {
		return nil, fmt.Errorf("sql.Open: %w", err)
	}

	for _, step := range []struct {
		what string
		run  func(*sql.DB) error
	}{
		{"apply tables", func(c *sql.DB) error { _, err := c.Exec(Tables); return err }},
		{"migrate", migrate},
		{"migrate lifecycle", func(c *sql.DB) error { return migrateLifecycle(c, time.Now().Unix()) }},
		{"migrate PR watches", migratePRWatches},
		{"apply view", applyView},
	} {
		if err := step.run(conn); err != nil {
			conn.Close()
			return nil, fmt.Errorf("%s: %w", step.what, err)
		}
	}

	return conn, nil
}

// dsn builds the modernc.org/sqlite DSN for path: a file: URI carrying each of
// Pragmas as a _pragma parameter. path is made absolute and escaped, so a path
// holding ?, # or % names the file it says rather than starting the query.
func dsn(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", path, err)
	}
	u := url.URL{Scheme: "file", Path: filepath.ToSlash(abs)}
	params := make([]string, len(Pragmas))
	for i, p := range Pragmas {
		params[i] = "_pragma=" + url.QueryEscape(p)
	}
	u.RawQuery = strings.Join(params, "&")
	return u.String(), nil
}

// applyView makes the queue view match View.
//
// The common case -- the stored definition already is View -- is answered by
// a read and takes no lock. Otherwise the view is dropped and recreated in one
// BEGIN IMMEDIATE transaction, which re-reads the definition first: two Opens
// that both saw a stale view must not both recreate it, because outside a
// transaction one's CREATE lands between the other's DROP and CREATE and fails
// with "already exists".
func applyView(conn *sql.DB) error {
	ctx := context.Background()
	c, err := conn.Conn(ctx)
	if err != nil {
		return err
	}
	defer c.Close()

	current := func() (bool, error) {
		var stored sql.NullString
		err := c.QueryRowContext(ctx,
			"SELECT sql FROM sqlite_master WHERE type = 'view' AND name = 'queue'",
		).Scan(&stored)
		if err == sql.ErrNoRows {
			return false, nil
		}
		if err != nil {
			return false, fmt.Errorf("read view: %w", err)
		}
		return stored.String == View, nil
	}

	if ok, err := current(); err != nil || ok {
		return err
	}

	if _, err := c.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = c.ExecContext(ctx, "ROLLBACK")
		}
	}()

	if ok, err := current(); err != nil || ok {
		return err
	}
	if _, err := c.ExecContext(ctx, "DROP VIEW IF EXISTS queue"); err != nil {
		return fmt.Errorf("drop view: %w", err)
	}
	if _, err := c.ExecContext(ctx, View); err != nil {
		return fmt.Errorf("create view: %w", err)
	}
	if _, err := c.ExecContext(ctx, "COMMIT"); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	committed = true
	return nil
}

// migrate brings an existing database up to the current Tables definition.
//
// Only added columns so far, which SQLite can do in place. ALTER TABLE ... ADD
// COLUMN errors when the column is already there and SQLite has no IF NOT
// EXISTS for it, so each one is asked for first -- Open runs on every hook
// invocation, and a migration that fails on the second run would take the whole
// ledger down with it.
//
// The asking and the adding are a check-then-act, so two Opens that both find a
// column missing would both ALTER and the later one fail with "duplicate column
// name". It is guarded the way applyView is: the unlocked scan lets an
// up-to-date database return without the write lock, and only when something is
// missing does BEGIN IMMEDIATE serialize the Opens and every column get asked
// for again inside it.
func migrate(conn *sql.DB) error {
	ctx := context.Background()
	c, err := conn.Conn(ctx)
	if err != nil {
		return err
	}
	defer c.Close()

	type column struct{ table, name, ddl string }
	cols := []column{
		{"sessions", "config_dir", "ALTER TABLE sessions ADD COLUMN config_dir TEXT"},
		{"sessions", "waiting_event_id", "ALTER TABLE sessions ADD COLUMN waiting_event_id INTEGER"},
		{"sessions", "done_at", "ALTER TABLE sessions ADD COLUMN done_at INTEGER"},
		{"sessions", "kind", "ALTER TABLE sessions ADD COLUMN kind TEXT"},
		{"sessions", "memo", "ALTER TABLE sessions ADD COLUMN memo TEXT"},
		{"sessions", "pin_note", "ALTER TABLE sessions ADD COLUMN pin_note TEXT"},
		{"sessions", "pin_pr", "ALTER TABLE sessions ADD COLUMN pin_pr TEXT"},
		{"sessions", "pin_cursor", "ALTER TABLE sessions ADD COLUMN pin_cursor TEXT"},
		{"sessions", "pin_seen_at", "ALTER TABLE sessions ADD COLUMN pin_seen_at INTEGER"},
		{"sessions", "pin_delivered_at", "ALTER TABLE sessions ADD COLUMN pin_delivered_at INTEGER"},
		{"sessions", "pin_delivered_upto", "ALTER TABLE sessions ADD COLUMN pin_delivered_upto TEXT"},
		{"sessions", "pin_failures", "ALTER TABLE sessions ADD COLUMN pin_failures INTEGER"},
		{"sessions", "pin_halted_upto", "ALTER TABLE sessions ADD COLUMN pin_halted_upto TEXT"},
		{"session_links", "repo", "ALTER TABLE session_links ADD COLUMN repo TEXT"},
		{"session_links", "branch", "ALTER TABLE session_links ADD COLUMN branch TEXT"},
		{"session_links", "pr", "ALTER TABLE session_links ADD COLUMN pr INTEGER"},
	}

	missing := func() ([]column, error) {
		var out []column
		for _, m := range cols {
			has, err := hasColumn(ctx, c, m.table, m.name)
			if err != nil {
				return nil, err
			}
			if !has {
				out = append(out, m)
			}
		}
		return out, nil
	}

	if todo, err := missing(); err != nil || len(todo) == 0 {
		return err
	}

	if _, err := c.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = c.ExecContext(ctx, "ROLLBACK")
		}
	}()

	// Re-ask under the write lock: another Open may have added them since.
	todo, err := missing()
	if err != nil {
		return err
	}
	for _, m := range todo {
		if _, err := c.ExecContext(ctx, m.ddl); err != nil {
			return fmt.Errorf("add %s.%s: %w", m.table, m.name, err)
		}
	}
	if _, err := c.ExecContext(ctx, "COMMIT"); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	committed = true
	return nil
}

// rowQuerier is what hasColumn needs, satisfied by *sql.Conn as well as *sql.DB.
type rowQuerier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// hasColumn reports whether table already has column, via pragma_table_info --
// the table-valued form, so the answer comes back as a row that can be counted
// rather than a result set to scan.
func hasColumn(ctx context.Context, q rowQuerier, table, column string) (bool, error) {
	var n int
	if err := q.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?", table, column,
	).Scan(&n); err != nil {
		return false, fmt.Errorf("inspect %s.%s: %w", table, column, err)
	}
	return n > 0, nil
}

// migratePRWatches moves each PR watch from the pin_* columns, where it used
// to be an attribute of the pin, into pr_watches, and takes that session's pin
// off. A pin put on by hand and one that came with `pin --pr` cannot be told
// apart, so every pin with a watch comes off; the pin_note goes with it, as
// the watch's note.
//
// It is not gated on user_version: once a row's pin_pr is NULL it has nothing
// left to move, so running again is a no-op, and a binary from before the move
// that writes a pin_pr later has it picked up by the next Open. The check
// outside the transaction lets every Open with nothing to move return without
// taking the write lock, for the reason migrateLifecycle's first read does.
func migratePRWatches(conn *sql.DB) error {
	var pending bool
	if err := conn.QueryRow("SELECT EXISTS (SELECT 1 FROM sessions WHERE pin_pr IS NOT NULL)").Scan(&pending); err != nil {
		return fmt.Errorf("look for PR pins: %w", err)
	}
	if !pending {
		return nil
	}
	tx, err := conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`
		INSERT OR IGNORE INTO pr_watches(session_id, pr, cursor, seen_at, delivered_at, delivered_upto, failures, halted_upto, note)
		SELECT session_id, pin_pr, pin_cursor, pin_seen_at, pin_delivered_at, pin_delivered_upto, pin_failures, pin_halted_upto, pin_note
		FROM sessions WHERE pin_pr IS NOT NULL`); err != nil {
		return fmt.Errorf("copy PR pins: %w", err)
	}
	if _, err := tx.Exec(`
		UPDATE sessions
		SET waiting_event_id = NULL, pin_note = NULL, pin_pr = NULL, pin_cursor = NULL, pin_seen_at = NULL,
		    pin_delivered_at = NULL, pin_delivered_upto = NULL, pin_failures = NULL, pin_halted_upto = NULL
		WHERE pin_pr IS NOT NULL`); err != nil {
		return fmt.Errorf("clear PR pins: %w", err)
	}
	return tx.Commit()
}

// lifecycleVersion is the PRAGMA user_version migrateLifecycle leaves behind.
const lifecycleVersion = 1

// migrateLifecycle sorts the sessions a database written before the work axis
// existed already holds into open and done, once.
//
// Before done_at, terminated_at meant both "the process ended" and "the work is
// over", so every closed row has to be told apart after the fact:
//
//  1. Closed within the last 7 days by anything but a human leaving the REPL
//     (SessionEnd reason prompt_input_exit or clear) stays open, and so gone:
//     a reboot, a reconcile ForcedEnd or a background job timing out ended the
//     process, not the work. 7 days is the old GC horizon -- older rows were
//     about to be deleted anyway.
//  2. A ForcedEnd written because a new session started in the same pane is a
//     /clear when that new session's SessionStart says source clear, and so
//     done. The new session's SessionStart is inserted in the same transaction
//     right after the ForcedEnd, so it is the next SessionStart on that pane by
//     id, within a couple of seconds.
//  3. Every other closed row is done, as of when it closed.
//  4. A waiting mark is kept only if it still held when the session closed --
//     it sat on the latest non-ended event. The mark used to lapse on the next
//     event; it now persists, so a lapsed one must not come back to life.
//  5. kind is filled in as background for a session recorded as a delegate
//     (session_links), interactive otherwise.
//
// The rule reads the end event that actually closed the row (the latest ended
// one), not merely the latest SessionEnd: a session resumed after a typed exit
// and then cut off by a reboot is open, though an older SessionEnd says
// prompt_input_exit.
//
// Gated on PRAGMA user_version rather than written to be re-runnable, because
// it is not: run again later, rule 3 would close every session gone since. The
// gate is checked twice. The first read, outside any transaction, lets every
// Open of an already-migrated ledger return without taking the write lock, so
// read-only callers (status, picker) never queue behind a hook's write. The
// second read, inside BEGIN IMMEDIATE, is the one that decides: two hooks
// opening an old ledger at once can both pass the first read, and only one of
// them may pass the second.
func migrateLifecycle(conn *sql.DB, now int64) error {
	ctx := context.Background()
	c, err := conn.Conn(ctx)
	if err != nil {
		return err
	}
	defer c.Close()

	var v int
	if err := c.QueryRowContext(ctx, "PRAGMA user_version").Scan(&v); err != nil {
		return fmt.Errorf("read user_version: %w", err)
	}
	if v >= lifecycleVersion {
		return nil
	}

	if _, err := c.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = c.ExecContext(ctx, "ROLLBACK")
		}
	}()

	// Re-read under the write lock: another Open may have migrated between the
	// unlocked read above and this transaction.
	if err := c.QueryRowContext(ctx, "PRAGMA user_version").Scan(&v); err != nil {
		return fmt.Errorf("read user_version: %w", err)
	}
	if v >= lifecycleVersion {
		return nil
	}

	for _, step := range []struct {
		what string
		sql  string
		args []any
	}{
		{"close finished sessions", `
			UPDATE sessions SET done_at = terminated_at
			WHERE terminated_at IS NOT NULL AND done_at IS NULL
			  AND NOT (
			    terminated_at >= ?1 - ?2
			    AND COALESCE((
			      SELECT CASE WHEN f.event_type = 'SessionEnd' AND json_valid(f.payload)
			                  THEN json_extract(f.payload, '$.reason') END
			      FROM events f
			      WHERE f.session_id = sessions.session_id AND f.state = 'ended'
			      ORDER BY f.id DESC LIMIT 1
			    ), '') NOT IN ('prompt_input_exit', 'clear')
			    AND NOT COALESCE((
			      SELECT f.event_type = 'ForcedEnd' AND COALESCE((
			        SELECT CASE WHEN json_valid(n.payload) THEN json_extract(n.payload, '$.source') END
			        FROM events n JOIN sessions ns ON ns.session_id = n.session_id
			        WHERE n.event_type = 'SessionStart' AND n.id > f.id
			          AND ns.session_id != sessions.session_id
			          AND ns.tmux_pane = sessions.tmux_pane
			          AND n.created_at - f.created_at BETWEEN 0 AND 2
			        ORDER BY n.id LIMIT 1
			      ), '') = 'clear'
			      FROM events f
			      WHERE f.session_id = sessions.session_id AND f.state = 'ended'
			      ORDER BY f.id DESC LIMIT 1
			    ), 0)
			  )`, []any{now, int64(7 * 24 * 3600)}},
		{"drop lapsed marks", `
			UPDATE sessions SET waiting_event_id = NULL
			WHERE waiting_event_id IS NOT NULL
			  AND waiting_event_id IS NOT (
			    SELECT MAX(id) FROM events
			    WHERE session_id = sessions.session_id AND state != 'ended'
			  )`, nil},
		{"fill kind", `
			UPDATE sessions SET kind = CASE
			    WHEN EXISTS (SELECT 1 FROM session_links WHERE child_short = substr(sessions.session_id, 1, 8))
			    THEN 'background' ELSE 'interactive' END
			WHERE kind IS NULL`, nil},
		{"stamp user_version", fmt.Sprintf("PRAGMA user_version = %d", lifecycleVersion), nil},
	} {
		if _, err := c.ExecContext(ctx, step.sql, step.args...); err != nil {
			return fmt.Errorf("%s: %w", step.what, err)
		}
	}
	if _, err := c.ExecContext(ctx, "COMMIT"); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	committed = true
	return nil
}
