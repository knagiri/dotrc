package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ErrDone is returned by the annotation writers for a session whose work is
// done: it is no longer listed, so a memo or a pin on it would never be seen.
var ErrDone = errors.New("session is done")

// flatten turns the tabs and line breaks in a free-text annotation into spaces
// and trims it. A picker line is tab separated with hidden columns after the
// visible ones, so a tab or a newline left in the text would shift those
// columns onto another session's values.
func flatten(s string) string {
	return strings.TrimSpace(strings.NewReplacer("\t", " ", "\n", " ", "\r", " ").Replace(s))
}

// nullIfEmpty is the stored form of an annotation: empty is no annotation.
func nullIfEmpty(s string) sql.NullString {
	return sql.NullString{String: s, Valid: s != ""}
}

// SetMemo replaces the free-text memo on an open session. An empty text (after
// flattening) clears it.
func SetMemo(conn *sql.DB, sessionID, text string) error {
	return annotate(conn, "set memo", sessionID,
		"UPDATE sessions SET memo = ?2 WHERE session_id = ?1 AND done_at IS NULL",
		nullIfEmpty(flatten(text)))
}

// SetPin pins an open session -- marks it waiting on something outside it --
// and sets the pin's note. A session already pinned keeps the event id it was
// pinned at. A nil note keeps the existing note; a non-nil one replaces it,
// and an empty one clears it.
func SetPin(conn *sql.DB, sessionID string, note *string) error {
	var keep bool
	var n sql.NullString
	if note == nil {
		keep = true
	} else {
		n = nullIfEmpty(flatten(*note))
	}
	return annotate(conn, "set pin", sessionID, `
		UPDATE sessions
		SET waiting_event_id = COALESCE(waiting_event_id,
		      (SELECT MAX(id) FROM events WHERE session_id = ?1), 0),
		    pin_note = CASE WHEN ?2 THEN pin_note ELSE ?3 END
		WHERE session_id = ?1 AND done_at IS NULL`, keep, n)
}

// ClearPin unpins an open session and drops the pin's note.
func ClearPin(conn *sql.DB, sessionID string) error {
	return annotate(conn, "clear pin", sessionID,
		"UPDATE sessions SET waiting_event_id = NULL, pin_note = NULL WHERE session_id = ?1 AND done_at IS NULL")
}

// annotate runs an UPDATE that touches only an open sessionID (its first
// argument is ?1) and, when it changed nothing, tells a done session (ErrDone)
// from an unknown one (sql.ErrNoRows).
func annotate(conn *sql.DB, what, sessionID, query string, args ...any) error {
	res, err := conn.Exec(query, append([]any{sessionID}, args...)...)
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	if n > 0 {
		return nil
	}
	var done bool
	err = conn.QueryRow("SELECT done_at IS NOT NULL FROM sessions WHERE session_id = ?", sessionID).Scan(&done)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%s: no session %s: %w", what, sessionID, err)
	}
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	if done {
		return fmt.Errorf("%s: %s: %w", what, sessionID, ErrDone)
	}
	return fmt.Errorf("%s: %s: nothing updated", what, sessionID)
}

// Memo returns the memo on sessionID, empty when it has none. Unlike the
// writers it reads a done session too.
func Memo(conn *sql.DB, sessionID string) (string, error) {
	var m sql.NullString
	if err := conn.QueryRow("SELECT memo FROM sessions WHERE session_id = ?", sessionID).Scan(&m); err != nil {
		return "", fmt.Errorf("read memo: %w", err)
	}
	return m.String, nil
}
