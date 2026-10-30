package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// NavLimit is how many entries the jump history keeps. PushNav drops the
// oldest beyond it.
const NavLimit = 50

// NavEntry is one entry of the jump history.
type NavEntry struct {
	Pos       int64
	SessionID string
}

// NavHistory returns the jump history oldest first, and the index into it of
// the cursor. The index is -1 when the history is empty.
func NavHistory(conn *sql.DB) ([]NavEntry, int, error) {
	return navHistory(conn)
}

type querier interface {
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
}

func navHistory(q querier) ([]NavEntry, int, error) {
	rows, err := q.Query("SELECT pos, session_id FROM nav_history ORDER BY pos")
	if err != nil {
		return nil, -1, fmt.Errorf("nav history: %w", err)
	}
	defer rows.Close()
	var out []NavEntry
	for rows.Next() {
		var e NavEntry
		if err := rows.Scan(&e.Pos, &e.SessionID); err != nil {
			return nil, -1, err
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, -1, err
	}

	var cur int64
	err = q.QueryRow("SELECT pos FROM nav_cursor WHERE id = 1").Scan(&cur)
	if errors.Is(err, sql.ErrNoRows) {
		if len(out) == 0 {
			return out, -1, nil
		}
		return out, len(out) - 1, nil
	}
	if err != nil {
		return nil, -1, fmt.Errorf("nav cursor: %w", err)
	}
	// The cursor always names an entry PushNav kept; a cursor that does not
	// (the table edited by hand) reads as the newest entry.
	idx := len(out) - 1
	for i, e := range out {
		if e.Pos == cur {
			idx = i
		}
	}
	return out, idx, nil
}

// connTx lets navHistory and setNavCursor run on a *sql.Conn, which only has
// the Context forms of Query and Exec.
type connTx struct{ c *sql.Conn }

func (t connTx) Query(q string, args ...any) (*sql.Rows, error) {
	return t.c.QueryContext(context.Background(), q, args...)
}

func (t connTx) QueryRow(q string, args ...any) *sql.Row {
	return t.c.QueryRowContext(context.Background(), q, args...)
}

func (t connTx) Exec(q string, args ...any) (sql.Result, error) {
	return t.c.ExecContext(context.Background(), q, args...)
}

// PushNav records a picker jump from the session origin to the session
// target. origin is "" when the session the picker was opened over is not
// known.
//
//  1. Before the first entry is pushed, everything after the cursor is
//     dropped, the way a browser drops its forward history on a new
//     navigation. When nothing ends up pushed (target is the entry already at
//     the cursor), the forward side is left alone.
//  2. origin is pushed when it is not the entry at the cursor, so the first
//     jump already has somewhere to go back to.
//  3. target is pushed and becomes the cursor, unless it is the entry already
//     at the cursor: no entry is ever pushed twice in a row.
//
// Entries beyond NavLimit are dropped oldest first.
//
// The transaction is BEGIN IMMEDIATE: it reads before it writes, and a
// deferred transaction that read first fails with SQLITE_BUSY_SNAPSHOT, without
// waiting for busy_timeout, when another connection commits in between. Same
// reason as migrateLifecycle.
func PushNav(conn *sql.DB, origin, target string) (err error) {
	ctx := context.Background()
	c, err := conn.Conn(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	if _, err := c.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = c.ExecContext(ctx, "ROLLBACK")
		}
	}()
	tx := connTx{c}

	hist, idx, err := navHistory(tx)
	if err != nil {
		return err
	}
	at := func() string {
		if idx < 0 {
			return ""
		}
		return hist[idx].SessionID
	}
	dropped := false
	// dropForward deletes everything after the cursor. Once per call, right
	// before the first push.
	dropForward := func() error {
		if dropped || idx < 0 {
			return nil
		}
		dropped = true
		if _, err := tx.Exec("DELETE FROM nav_history WHERE pos > ?", hist[idx].Pos); err != nil {
			return fmt.Errorf("drop forward history: %w", err)
		}
		hist = hist[:idx+1]
		return nil
	}
	// push appends id right after the cursor and moves the cursor onto it. The
	// forward side is dropped first, or the pos would collide.
	push := func(id string) error {
		if err := dropForward(); err != nil {
			return err
		}
		var pos int64 = 1
		if idx >= 0 {
			pos = hist[idx].Pos + 1
		}
		if _, err := tx.Exec("INSERT INTO nav_history(pos, session_id) VALUES (?, ?)", pos, id); err != nil {
			return fmt.Errorf("push history: %w", err)
		}
		hist = append(hist, NavEntry{Pos: pos, SessionID: id})
		idx = len(hist) - 1
		return nil
	}

	for _, id := range []string{origin, target} {
		if id == "" || id == at() {
			continue
		}
		if err := push(id); err != nil {
			return err
		}
	}
	if idx >= 0 {
		cur := hist[idx].Pos
		if _, err := tx.Exec("DELETE FROM nav_history WHERE pos <= ?", cur-NavLimit); err != nil {
			return fmt.Errorf("trim history: %w", err)
		}
		if err := setNavCursor(tx, cur); err != nil {
			return err
		}
	}
	if _, err := c.ExecContext(ctx, "COMMIT"); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	committed = true
	return nil
}

// SetNavCursor moves the cursor to pos without touching the history.
func SetNavCursor(conn *sql.DB, pos int64) error {
	return setNavCursor(conn, pos)
}

func setNavCursor(x execer, pos int64) error {
	if _, err := x.Exec(
		"INSERT INTO nav_cursor(id, pos) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET pos = excluded.pos", pos,
	); err != nil {
		return fmt.Errorf("set nav cursor: %w", err)
	}
	return nil
}

// SessionInPane returns the running session the ledger records in pane, or ""
// when there is none.
func SessionInPane(conn *sql.DB, pane string) (string, error) {
	if pane == "" {
		return "", nil
	}
	var id string
	err := conn.QueryRow(
		"SELECT session_id FROM sessions WHERE tmux_pane = ? AND terminated_at IS NULL ORDER BY started_at DESC, rowid DESC LIMIT 1",
		pane,
	).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("session in pane: %w", err)
	}
	return id, nil
}

// NavTarget is what walking to a history entry needs to know about its
// session: the ledger pane, withheld once the process is gone (see View), and
// the config dir whose roster can locate it. found is false for a session the
// ledger no longer has.
func NavTarget(conn *sql.DB, sessionID string) (pane, configDir string, found bool, err error) {
	var p, dir sql.NullString
	err = conn.QueryRow(
		"SELECT CASE WHEN terminated_at IS NULL THEN tmux_pane END, config_dir FROM sessions WHERE session_id = ?",
		sessionID,
	).Scan(&p, &dir)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", false, nil
	}
	if err != nil {
		return "", "", false, fmt.Errorf("nav target: %w", err)
	}
	return p.String, ConfigDirOf(dir), true, nil
}
