package db

import (
	"database/sql"
	"errors"
	"path/filepath"
	"slices"
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

const watchedPR = "example-org/example-repo#3"

// noteOfWatch reads the note on the session's watch of watchedPR.
func noteOfWatch(t *testing.T, conn *sql.DB, sid string) sql.NullString {
	t.Helper()
	var note sql.NullString
	if err := conn.QueryRow("SELECT note FROM pr_watches WHERE session_id = ? AND pr = ?", sid, watchedPR).Scan(&note); err != nil {
		t.Fatalf("read note of %s: %v", sid, err)
	}
	return note
}

// Activity from before the watch was set is not news to the session that set
// it: the cursor starts there. A watch does not pin the session.
func TestSetPRWatch_SetsCursorToNow(t *testing.T) {
	conn := openAnnotate(t)
	at := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	if err := SetPRWatch(conn, "a", watchedPR, nil, at); err != nil {
		t.Fatalf("SetPRWatch: %v", err)
	}
	if _, _, pinned := annotationsOf(t, conn, "a"); pinned {
		t.Error("SetPRWatch pinned the session")
	}
	ws, err := PRWatches(conn)
	if err != nil || len(ws) != 1 {
		t.Fatalf("PRWatches = %v, %v", ws, err)
	}
	if p := ws[0]; p.SessionID != "a" || p.PR != watchedPR || !p.Cursor.Equal(at) || p.SeenAt != 0 || p.DeliveredAt != 0 || !p.DeliveredUpTo.IsZero() {
		t.Errorf("PRWatches[0] = %+v", p)
	}
}

// Setting a watch again on the same PR starts it over: the cursor moves to now,
// and the delivery record and any stop go. A nil note keeps the note.
func TestSetPRWatch_AgainResets(t *testing.T) {
	conn := openAnnotate(t)
	note := "human review"
	if err := SetPRWatch(conn, "a", watchedPR, &note, time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(`UPDATE pr_watches SET seen_at = 5, delivered_at = 7, delivered_upto = '2026-10-26T09:00:00Z',
		failures = 3, halted_upto = '2026-10-26T09:00:00Z'`); err != nil {
		t.Fatal(err)
	}
	if err := SetPRWatch(conn, "a", watchedPR, nil, time.Unix(200, 0)); err != nil {
		t.Fatal(err)
	}
	ws, err := PRWatches(conn)
	if err != nil || len(ws) != 1 {
		t.Fatalf("PRWatches = %v, %v", ws, err)
	}
	if p := ws[0]; !p.Cursor.Equal(time.Unix(200, 0)) || p.SeenAt != 0 || p.DeliveredAt != 0 || !p.DeliveredUpTo.IsZero() || p.Failures != 0 || !p.HaltedUpTo.IsZero() {
		t.Errorf("after setting it again: %+v", p)
	}
	if got := noteOfWatch(t, conn, "a"); got.String != note {
		t.Errorf("nil note did not keep the note: %v", got)
	}
	empty := ""
	if err := SetPRWatch(conn, "a", watchedPR, &empty, time.Unix(300, 0)); err != nil {
		t.Fatal(err)
	}
	if got := noteOfWatch(t, conn, "a"); got.Valid {
		t.Errorf("empty note did not clear the note: %v", got)
	}
}

func TestSetPRWatch_DoneOrUnknownFails(t *testing.T) {
	conn := openAnnotate(t)
	if _, err := MarkDone(conn, "a", 100); err != nil {
		t.Fatal(err)
	}
	if err := SetPRWatch(conn, "a", watchedPR, nil, time.Unix(100, 0)); !errors.Is(err, ErrDone) {
		t.Errorf("done session: err = %v, want ErrDone", err)
	}
	if err := SetPRWatch(conn, "nope", watchedPR, nil, time.Unix(100, 0)); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("unknown session: err = %v, want sql.ErrNoRows", err)
	}
}

// Taking a pin on or off leaves the watch alone, its delivery record and its
// stop included.
func TestPinWrites_LeaveWatch(t *testing.T) {
	note := "n"
	for name, write := range map[string]func(*sql.DB) error{
		"SetPin":     func(c *sql.DB) error { return SetPin(c, "a", &note) },
		"ClearPin":   func(c *sql.DB) error { return ClearPin(c, "a") },
		"ToggleMark": func(c *sql.DB) error { _, err := ToggleMark(c, "a"); return err },
	} {
		t.Run(name, func(t *testing.T) {
			conn := openAnnotate(t)
			if err := SetPRWatch(conn, "a", watchedPR, nil, time.Unix(100, 0)); err != nil {
				t.Fatal(err)
			}
			halted := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
			if _, err := conn.Exec("UPDATE pr_watches SET seen_at = 5, delivered_at = 7, failures = 3, halted_upto = ?", halted.Format(time.RFC3339)); err != nil {
				t.Fatal(err)
			}
			if err := write(conn); err != nil {
				t.Fatal(err)
			}
			ws, err := PRWatches(conn)
			if err != nil || len(ws) != 1 {
				t.Fatalf("after %s: PRWatches = %v, %v", name, ws, err)
			}
			if p := ws[0]; p.SeenAt != 5 || p.DeliveredAt != 7 || p.Failures != 3 || !p.HaltedUpTo.Equal(halted) {
				t.Errorf("after %s: %+v", name, p)
			}
		})
	}
}

// Clearing a watch takes off that one watch and nothing else: not another of
// the session's watches, not another session's, not the pin.
func TestClearPRWatch(t *testing.T) {
	conn := openAnnotate(t)
	insertSession(t, conn, "b", "")
	insertEvent(t, conn, "b", "Stop", "idle_done", 10)
	const other = "example-org/example-repo#4"
	for _, w := range [][2]string{{"a", watchedPR}, {"a", other}, {"b", watchedPR}} {
		if err := SetPRWatch(conn, w[0], w[1], nil, time.Unix(100, 0)); err != nil {
			t.Fatal(err)
		}
	}
	if err := SetPin(conn, "a", nil); err != nil {
		t.Fatal(err)
	}
	if n, err := ClearPRWatch(conn, "a", watchedPR); n != 1 || err != nil {
		t.Fatalf("ClearPRWatch = %d, %v", n, err)
	}
	ws, err := PRWatches(conn)
	if err != nil || len(ws) != 2 || ws[0].SessionID != "a" || ws[0].PR != other || ws[1].SessionID != "b" {
		t.Fatalf("after ClearPRWatch: %+v, %v", ws, err)
	}
	if _, _, pinned := annotationsOf(t, conn, "a"); !pinned {
		t.Error("ClearPRWatch took the pin off")
	}
	if n, err := ClearPRWatch(conn, "a", watchedPR); n != 0 || err != nil {
		t.Errorf("second ClearPRWatch = %d, %v", n, err)
	}
	if err := SetPRWatch(conn, "a", watchedPR, nil, time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	if n, err := ClearPRWatches(conn, "a"); n != 2 || err != nil {
		t.Fatalf("ClearPRWatches = %d, %v", n, err)
	}
	ws, err = PRWatches(conn)
	if err != nil || len(ws) != 1 || ws[0].SessionID != "b" {
		t.Errorf("after ClearPRWatches: %+v, %v", ws, err)
	}
	if _, _, pinned := annotationsOf(t, conn, "a"); !pinned {
		t.Error("ClearPRWatches took the pin off")
	}
}

// Every watch of an open session is listed, whether the session is pinned or
// not and running or gone; a plain pin is not a watch, and a done session is
// not watched.
func TestPRWatches_Selection(t *testing.T) {
	conn := openAnnotate(t)
	for _, id := range []string{"plain", "done", "gone", "pinned"} {
		insertSession(t, conn, id, "")
		insertEvent(t, conn, id, "Stop", "idle_done", 10)
	}
	if err := SetPin(conn, "plain", nil); err != nil {
		t.Fatal(err)
	}
	if err := SetPin(conn, "pinned", nil); err != nil {
		t.Fatal(err)
	}
	for _, w := range [][2]string{
		{"done", "example-org/example-repo#1"},
		{"a", "example-org/example-repo#2"},
		{"a", "example-org/example-repo#3"},
		{"gone", "example-org/example-repo#4"},
		{"pinned", "example-org/example-repo#5"},
	} {
		if err := SetPRWatch(conn, w[0], w[1], nil, time.Unix(100, 0)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := MarkDone(conn, "done", 200); err != nil {
		t.Fatal(err)
	}
	terminate(t, conn, "gone", 100)
	ws, err := PRWatches(conn)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, w := range ws {
		got = append(got, w.SessionID+" "+w.PR)
	}
	want := []string{"a example-org/example-repo#2", "a example-org/example-repo#3", "gone example-org/example-repo#4", "pinned example-org/example-repo#5"}
	if !slices.Equal(got, want) {
		t.Errorf("PRWatches = %q, want %q", got, want)
	}
	if !ws[2].Gone || ws[0].Gone {
		t.Errorf("Gone: %+v", ws)
	}
}

// A delivery is recorded without moving the cursor; AdvancePRCursor moves it
// and drops the record. A merge or close records no cursor to move to.
func TestSetPRDelivered(t *testing.T) {
	conn := openAnnotate(t)
	pr := watchedPR
	if err := SetPRWatch(conn, "a", pr, nil, time.Unix(100, 0)); err != nil {
		t.Fatal(err)
	}
	upTo := time.Date(2026, 10, 26, 10, 40, 0, 0, time.UTC)
	if err := SetPRDelivered(conn, "a", pr, 500, upTo); err != nil {
		t.Fatal(err)
	}
	ws, err := PRWatches(conn)
	if err != nil || len(ws) != 1 {
		t.Fatalf("PRWatches = %v, %v", ws, err)
	}
	if p := ws[0]; p.DeliveredAt != 500 || !p.DeliveredUpTo.Equal(upTo) || !p.Cursor.Equal(time.Unix(100, 0)) {
		t.Errorf("after SetPRDelivered: %+v", p)
	}
	// Another PR's write does not touch this watch.
	if err := SetPRDelivered(conn, "a", "example-org/example-repo#4", 0, time.Time{}); err != nil {
		t.Fatal(err)
	}
	ws, _ = PRWatches(conn)
	if p := ws[0]; p.DeliveredAt != 500 {
		t.Errorf("another PR's write changed the watch: %+v", p)
	}
	if err := AdvancePRCursor(conn, "a", pr, upTo); err != nil {
		t.Fatal(err)
	}
	ws, _ = PRWatches(conn)
	if p := ws[0]; p.DeliveredAt != 0 || !p.DeliveredUpTo.IsZero() || !p.Cursor.Equal(upTo) {
		t.Errorf("after AdvancePRCursor: %+v", p)
	}
	if err := SetPRDelivered(conn, "a", pr, 600, time.Time{}); err != nil {
		t.Fatal(err)
	}
	ws, _ = PRWatches(conn)
	if p := ws[0]; p.DeliveredAt != 600 || !p.DeliveredUpTo.IsZero() {
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
// PRWatches. It marks the watch's note, not the pin's, setting the watch again
// lifts the stop, and a write for another PR changes nothing.
func TestFailPRDelivery(t *testing.T) {
	const pr, note = watchedPR, "[stopped]"
	upTo := time.Date(2026, 10, 26, 10, 40, 0, 0, time.UTC)
	stop := func(t *testing.T, conn *sql.DB) {
		t.Helper()
		if err := SetPRWatch(conn, "a", pr, nil, time.Unix(100, 0)); err != nil {
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
	ws, err := PRWatches(conn)
	if err != nil || len(ws) != 1 {
		t.Fatalf("PRWatches = %v, %v", ws, err)
	}
	if p := ws[0]; p.Failures != 3 || !p.HaltedUpTo.Equal(upTo) || p.DeliveredAt != 0 {
		t.Errorf("after the third failure: %+v", p)
	}
	if got := noteOfWatch(t, conn, "a"); got.String != note {
		t.Errorf("note = %v", got)
	}
	if _, got, _ := annotationsOf(t, conn, "a"); got.Valid {
		t.Errorf("the stop marked the pin's note: %v", got)
	}

	if err := SetPRWatch(conn, "a", pr, nil, time.Unix(200, 0)); err != nil {
		t.Fatal(err)
	}
	var failures sql.NullInt64
	var halted sql.NullString
	if err := conn.QueryRow("SELECT failures, halted_upto FROM pr_watches WHERE session_id = 'a'").Scan(&failures, &halted); err != nil {
		t.Fatal(err)
	}
	if failures.Valid || halted.Valid {
		t.Errorf("setting the watch again kept the stop: failures=%v halted=%v", failures, halted)
	}
}
