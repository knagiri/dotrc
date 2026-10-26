package db

import (
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
)

func openAnnotate(t *testing.T) *sql.DB {
	t.Helper()
	conn, err := Open(filepath.Join(t.TempDir(), "a.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	insertSession(t, conn, "a", "%1")
	insertEvent(t, conn, "a", "Stop", "idle_done", 10)
	return conn
}

func annotationsOf(t *testing.T, conn *sql.DB, sid string) (memo, note sql.NullString, pinned bool) {
	t.Helper()
	if err := conn.QueryRow(
		"SELECT memo, pin_note, waiting_event_id IS NOT NULL FROM sessions WHERE session_id = ?", sid,
	).Scan(&memo, &note, &pinned); err != nil {
		t.Fatalf("read %s: %v", sid, err)
	}
	return memo, note, pinned
}

// A picker line is tab separated, and a tab or a newline in a memo would shift
// the hidden columns behind it onto another session's values.
func TestSetMemo_FlattensControlChars(t *testing.T) {
	conn := openAnnotate(t)
	if err := SetMemo(conn, "a", "one\ttwo\nthree\r\nfour"); err != nil {
		t.Fatalf("SetMemo: %v", err)
	}
	memo, _, _ := annotationsOf(t, conn, "a")
	if want := "one two three  four"; memo.String != want {
		t.Errorf("memo = %q, want %q", memo.String, want)
	}
	rows, err := ListRows(conn, ListOpts{})
	if err != nil || len(rows) != 1 {
		t.Fatalf("ListRows = %v, %v", rows, err)
	}
	if rows[0].Memo.String != "one two three  four" {
		t.Errorf("Row.Memo = %q", rows[0].Memo.String)
	}
}

func TestSetMemo_EmptyClears(t *testing.T) {
	conn := openAnnotate(t)
	if err := SetMemo(conn, "a", "x"); err != nil {
		t.Fatalf("SetMemo: %v", err)
	}
	if err := SetMemo(conn, "a", ""); err != nil {
		t.Fatalf("SetMemo(empty): %v", err)
	}
	if memo, _, _ := annotationsOf(t, conn, "a"); memo.Valid {
		t.Errorf("memo = %q after clearing, want NULL", memo.String)
	}
}

func TestPin_DoneSessionRejected(t *testing.T) {
	conn := openAnnotate(t)
	if _, err := conn.Exec("UPDATE sessions SET done_at = unixepoch() WHERE session_id = 'a'"); err != nil {
		t.Fatal(err)
	}
	note := "n"
	for name, err := range map[string]error{
		"SetMemo":  SetMemo(conn, "a", "m"),
		"SetPin":   SetPin(conn, "a", &note),
		"ClearPin": ClearPin(conn, "a"),
	} {
		if !errors.Is(err, ErrDone) {
			t.Errorf("%s on a done session = %v, want ErrDone", name, err)
		}
	}
	memo, gotNote, pinned := annotationsOf(t, conn, "a")
	if memo.Valid || gotNote.Valid || pinned {
		t.Errorf("done session written: memo=%v note=%v pinned=%v", memo, gotNote, pinned)
	}
}

func TestAnnotate_UnknownSession(t *testing.T) {
	conn := openAnnotate(t)
	for name, err := range map[string]error{
		"SetMemo":  SetMemo(conn, "nope", "m"),
		"SetPin":   SetPin(conn, "nope", nil),
		"ClearPin": ClearPin(conn, "nope"),
	} {
		if !errors.Is(err, sql.ErrNoRows) {
			t.Errorf("%s on an unknown session = %v, want sql.ErrNoRows", name, err)
		}
	}
}

func TestSetPin_KeepsNoteWhenNil(t *testing.T) {
	conn := openAnnotate(t)
	note := "waiting on review"
	if err := SetPin(conn, "a", &note); err != nil {
		t.Fatalf("SetPin: %v", err)
	}
	if err := SetPin(conn, "a", nil); err != nil {
		t.Fatalf("SetPin(nil): %v", err)
	}
	_, got, pinned := annotationsOf(t, conn, "a")
	if !pinned || got.String != note {
		t.Errorf("after SetPin(nil): pinned=%v note=%q; want true, %q", pinned, got.String, note)
	}
	empty := ""
	if err := SetPin(conn, "a", &empty); err != nil {
		t.Fatalf("SetPin(empty): %v", err)
	}
	if _, got, pinned := annotationsOf(t, conn, "a"); !pinned || got.Valid {
		t.Errorf("after SetPin(empty): pinned=%v note=%v; want true, NULL", pinned, got)
	}
}

// SetPin on a session already pinned keeps the event id it was pinned at.
func TestSetPin_KeepsEventID(t *testing.T) {
	conn := openAnnotate(t)
	if err := SetPin(conn, "a", nil); err != nil {
		t.Fatalf("SetPin: %v", err)
	}
	var first int64
	_ = conn.QueryRow("SELECT waiting_event_id FROM sessions WHERE session_id = 'a'").Scan(&first)
	insertEvent(t, conn, "a", "UserPromptSubmit", "working", 0)
	if err := SetPin(conn, "a", nil); err != nil {
		t.Fatalf("SetPin: %v", err)
	}
	var second int64
	_ = conn.QueryRow("SELECT waiting_event_id FROM sessions WHERE session_id = 'a'").Scan(&second)
	if first == 0 || first != second {
		t.Errorf("waiting_event_id = %d then %d; want a non-zero id kept", first, second)
	}
}

func TestClearPin(t *testing.T) {
	conn := openAnnotate(t)
	note := "n"
	if err := SetPin(conn, "a", &note); err != nil {
		t.Fatalf("SetPin: %v", err)
	}
	if err := ClearPin(conn, "a"); err != nil {
		t.Fatalf("ClearPin: %v", err)
	}
	if _, got, pinned := annotationsOf(t, conn, "a"); pinned || got.Valid {
		t.Errorf("after ClearPin: pinned=%v note=%v", pinned, got)
	}
}

func TestToggleMark_ClearsNote(t *testing.T) {
	conn := openAnnotate(t)
	note := "n"
	if err := SetPin(conn, "a", &note); err != nil {
		t.Fatalf("SetPin: %v", err)
	}
	if on, err := ToggleMark(conn, "a"); err != nil || on {
		t.Fatalf("ToggleMark = %v, %v; want false, nil", on, err)
	}
	if _, got, pinned := annotationsOf(t, conn, "a"); pinned || got.Valid {
		t.Errorf("after unpinning by toggle: pinned=%v note=%v", pinned, got)
	}
	rows, err := ListRows(conn, ListOpts{})
	if err != nil || len(rows) != 1 || rows[0].PinNote.Valid {
		t.Errorf("ListRows = %+v, %v", rows, err)
	}
}
