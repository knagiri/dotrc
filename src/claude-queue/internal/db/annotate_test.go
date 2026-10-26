package db

import (
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"
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

func TestParsePRRef(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"example-org/example-repo#12", "example-org/example-repo#12"},
		{"https://github.com/example-org/example-repo/pull/12", "example-org/example-repo#12"},
		{"https://github.com/example-org/example-repo/pull/12/files", "example-org/example-repo#12"},
		{" example-org/example-repo#7 ", "example-org/example-repo#7"},
	} {
		got, err := ParsePRRef(tc.in)
		if err != nil || got != tc.want {
			t.Errorf("ParsePRRef(%q) = %q, %v; want %q", tc.in, got, err, tc.want)
		}
	}
	for _, bad := range []string{"", "12", "#12", "example-repo#12", "a/b#", "a/b#x", "a/b#0", "a/b/c#1",
		"https://github.com/a/b/issues/1", "https://example.com/a/b/pull/1", "a b/c#1"} {
		if got, err := ParsePRRef(bad); err == nil {
			t.Errorf("ParsePRRef(%q) = %q, want an error", bad, got)
		}
	}
}

func prPinOf(t *testing.T, conn *sql.DB, sid string) (pr, cursor sql.NullString, seen sql.NullInt64) {
	t.Helper()
	if err := conn.QueryRow(
		"SELECT pin_pr, pin_cursor, pin_seen_at FROM sessions WHERE session_id = ?", sid,
	).Scan(&pr, &cursor, &seen); err != nil {
		t.Fatalf("read %s: %v", sid, err)
	}
	return pr, cursor, seen
}

// Activity from before the pin was put on is not news to the session that
// pinned itself: the cursor starts at the pin.
func TestSetPinPR_SetsCursorToNow(t *testing.T) {
	conn := openAnnotate(t)
	at := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	if _, err := conn.Exec("UPDATE sessions SET pin_seen_at = 5, pin_delivered_at = 7, pin_delivered_upto = 'x' WHERE session_id = 'a'"); err != nil {
		t.Fatal(err)
	}
	if err := SetPinPR(conn, "a", "example-org/example-repo#3", at); err != nil {
		t.Fatalf("SetPinPR: %v", err)
	}
	pr, cursor, seen := prPinOf(t, conn, "a")
	if pr.String != "example-org/example-repo#3" || cursor.String != "2026-10-26T09:00:00Z" || seen.Valid {
		t.Errorf("pin = %v, %v, %v", pr, cursor, seen)
	}
	if _, _, pinned := annotationsOf(t, conn, "a"); !pinned {
		t.Error("SetPinPR did not pin the session")
	}
	pins, err := PRPins(conn)
	if err != nil || len(pins) != 1 {
		t.Fatalf("PRPins = %v, %v", pins, err)
	}
	if p := pins[0]; p.SessionID != "a" || p.PR != "example-org/example-repo#3" || !p.Cursor.Equal(at) || p.SeenAt != 0 || p.DeliveredAt != 0 || !p.DeliveredUpTo.IsZero() {
		t.Errorf("PRPins[0] = %+v", p)
	}
}

func TestClearPin_ClearsPR(t *testing.T) {
	for name, unpin := range map[string]func(*sql.DB) error{
		"ClearPin":   func(c *sql.DB) error { return ClearPin(c, "a") },
		"ToggleMark": func(c *sql.DB) error { _, err := ToggleMark(c, "a"); return err },
		"ClearPRPin": func(c *sql.DB) error { return ClearPRPin(c, "a", "example-org/example-repo#3") },
	} {
		t.Run(name, func(t *testing.T) {
			conn := openAnnotate(t)
			if err := SetPinPR(conn, "a", "example-org/example-repo#3", time.Unix(100, 0)); err != nil {
				t.Fatal(err)
			}
			if _, err := conn.Exec("UPDATE sessions SET pin_seen_at = 5, pin_delivered_at = 7, pin_delivered_upto = 'x' WHERE session_id = 'a'"); err != nil {
				t.Fatal(err)
			}
			if err := unpin(conn); err != nil {
				t.Fatal(err)
			}
			if pr, cursor, seen := prPinOf(t, conn, "a"); pr.Valid || cursor.Valid || seen.Valid {
				t.Errorf("after %s: %v, %v, %v", name, pr, cursor, seen)
			}
			var at sql.NullInt64
			var upTo sql.NullString
			if err := conn.QueryRow("SELECT pin_delivered_at, pin_delivered_upto FROM sessions WHERE session_id = 'a'").Scan(&at, &upTo); err != nil {
				t.Fatal(err)
			}
			if at.Valid || upTo.Valid {
				t.Errorf("after %s: delivery record %v, %v", name, at, upTo)
			}
			if _, _, pinned := annotationsOf(t, conn, "a"); pinned {
				t.Errorf("after %s: still pinned", name)
			}
		})
	}
}

func TestPRPins_SkipsDoneAndPlainPins(t *testing.T) {
	conn := openAnnotate(t)
	for _, id := range []string{"plain", "done"} {
		insertSession(t, conn, id, "")
		insertEvent(t, conn, id, "Stop", "idle_done", 10)
	}
	if err := SetPin(conn, "plain", nil); err != nil {
		t.Fatal(err)
	}
	if err := SetPinPR(conn, "done", "example-org/example-repo#1", time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	if _, err := MarkDone(conn, "done", 200); err != nil {
		t.Fatal(err)
	}
	if err := SetPinPR(conn, "a", "example-org/example-repo#2", time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	pins, err := PRPins(conn)
	if err != nil {
		t.Fatal(err)
	}
	if len(pins) != 1 || pins[0].SessionID != "a" {
		t.Errorf("PRPins = %+v, want only a", pins)
	}
}

// A delivery is recorded without moving the cursor; AdvancePRCursor moves it
// and drops the record. A merge or close records no cursor to move to.
func TestSetPRDelivered(t *testing.T) {
	conn := openAnnotate(t)
	pr := "example-org/example-repo#3"
	if err := SetPinPR(conn, "a", pr, time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	upTo := time.Date(2026, 10, 26, 10, 40, 0, 0, time.UTC)
	if err := SetPRDelivered(conn, "a", pr, 500, upTo); err != nil {
		t.Fatal(err)
	}
	pins, err := PRPins(conn)
	if err != nil || len(pins) != 1 {
		t.Fatalf("PRPins = %v, %v", pins, err)
	}
	if p := pins[0]; p.DeliveredAt != 500 || !p.DeliveredUpTo.Equal(upTo) || !p.Cursor.Equal(time.Unix(100, 0)) {
		t.Errorf("after SetPRDelivered: %+v", p)
	}
	// Another PR's write does not touch this pin.
	if err := SetPRDelivered(conn, "a", "example-org/example-repo#4", 0, time.Time{}); err != nil {
		t.Fatal(err)
	}
	if err := AdvancePRCursor(conn, "a", pr, upTo); err != nil {
		t.Fatal(err)
	}
	pins, _ = PRPins(conn)
	if p := pins[0]; p.DeliveredAt != 0 || !p.DeliveredUpTo.IsZero() || !p.Cursor.Equal(upTo) {
		t.Errorf("after AdvancePRCursor: %+v", p)
	}
	if err := SetPRDelivered(conn, "a", pr, 600, time.Time{}); err != nil {
		t.Fatal(err)
	}
	pins, _ = PRPins(conn)
	if p := pins[0]; p.DeliveredAt != 600 || !p.DeliveredUpTo.IsZero() {
		t.Errorf("merge delivery: %+v", p)
	}
}

func TestPromptSince(t *testing.T) {
	conn := openAnnotate(t)
	// Only a UserPromptSubmit counts: a Stop at 200 is no prompt.
	for _, e := range []struct {
		typ, state string
		at         int64
	}{{"UserPromptSubmit", "working", 100}, {"Stop", "idle_done", 200}} {
		if _, err := conn.Exec("INSERT INTO events(session_id, event_type, state, created_at) VALUES ('a', ?, ?, ?)", e.typ, e.state, e.at); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		at   int64
		want bool
	}{{50, true}, {100, true}, {101, false}} {
		got, err := PromptSince(conn, "a", tc.at)
		if err != nil || got != tc.want {
			t.Errorf("PromptSince(%d) = %v, %v; want %v", tc.at, got, err, tc.want)
		}
	}
}

// FailPRDelivery counts failures and stops at max, reading back through
// PRPins; putting the pin on again (pin --pr; pin --note is
// TestPass_RetryCap's) or toggling it off with Tab (which drops the stop along with the watch), and a
// write for another PR changes nothing.
func TestFailPRDelivery(t *testing.T) {
	const pr, note = "example-org/example-repo#3", "[stopped]"
	upTo := time.Date(2026, 10, 26, 10, 40, 0, 0, time.UTC)
	stop := func(t *testing.T, conn *sql.DB) {
		t.Helper()
		if err := SetPinPR(conn, "a", pr, time.Unix(100, 0)); err != nil {
			t.Fatal(err)
		}
		for i := 1; i <= 3; i++ {
			if err := SetPRDelivered(conn, "a", pr, 500, upTo); err != nil {
				t.Fatal(err)
			}
			if n, err := FailPRDelivery(conn, "a", pr, 3, upTo, note); err != nil || n != i {
				t.Fatalf("failure %d: n=%d err=%v", i, n, err)
			}
		}
	}
	conn := openAnnotate(t)
	stop(t, conn)
	if n, err := FailPRDelivery(conn, "a", "example-org/example-repo#4", 3, upTo, note); n != 0 || err != nil {
		t.Errorf("another PR: n=%d err=%v", n, err)
	}
	pins, err := PRPins(conn)
	if err != nil || len(pins) != 1 {
		t.Fatalf("PRPins = %v, %v", pins, err)
	}
	if p := pins[0]; p.Failures != 3 || !p.HaltedUpTo.Equal(upTo) || p.DeliveredAt != 0 {
		t.Errorf("after the third failure: %+v", p)
	}
	if _, got, _ := annotationsOf(t, conn, "a"); got.String != note {
		t.Errorf("note = %v", got)
	}

	for name, repin := range map[string]func(*sql.DB) error{
		"pin --pr": func(c *sql.DB) error { return SetPinPR(c, "a", pr, time.Unix(200, 0)) },
		"tab":      func(c *sql.DB) error { _, err := ToggleMark(c, "a"); return err },
	} {
		conn := openAnnotate(t)
		stop(t, conn)
		if err := repin(conn); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var failures sql.NullInt64
		var halted sql.NullString
		if err := conn.QueryRow("SELECT pin_failures, pin_halted_upto FROM sessions WHERE session_id = 'a'").Scan(&failures, &halted); err != nil {
			t.Fatal(err)
		}
		if failures.Valid || halted.Valid {
			t.Errorf("%s kept the stop: failures=%v halted=%v", name, failures, halted)
		}
	}
}
