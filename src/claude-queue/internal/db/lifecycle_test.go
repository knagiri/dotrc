package db

import (
	"database/sql"
	"strings"
	"testing"
)

func doneAt(t *testing.T, conn *sql.DB, sid string) sql.NullInt64 {
	t.Helper()
	var at sql.NullInt64
	if err := conn.QueryRow("SELECT done_at FROM sessions WHERE session_id = ?", sid).Scan(&at); err != nil {
		t.Fatalf("read done_at %s: %v", sid, err)
	}
	return at
}

func setDone(t *testing.T, conn *sql.DB, sid string, agoSec int64) {
	t.Helper()
	if _, err := conn.Exec("UPDATE sessions SET done_at = unixepoch() - ? WHERE session_id = ?", agoSec, sid); err != nil {
		t.Fatalf("set done %s: %v", sid, err)
	}
}

func sessionCount(t *testing.T, conn *sql.DB, sid string) int {
	t.Helper()
	var n int
	_ = conn.QueryRow("SELECT COUNT(*) FROM sessions WHERE session_id = ?", sid).Scan(&n)
	return n
}

// Ids shaped like real ones, because children are linked by 8-char prefix.
const (
	idParent = "aaaaaaaa-0000-0000-0000-000000000000"
	idChild  = "bbbbbbbb-0000-0000-0000-000000000000"
	idGrand  = "cccccccc-0000-0000-0000-000000000000"
	idOther  = "dddddddd-0000-0000-0000-000000000000"
)

func TestMarkDone_CascadesToDescendants(t *testing.T) {
	conn := openTest(t)
	for _, id := range []string{idParent, idChild, idGrand, idOther} {
		insertSession(t, conn, id, "")
	}
	_ = LinkSession(conn, "bbbbbbbb", idParent)
	_ = LinkSession(conn, "cccccccc", idChild)

	n, err := MarkDone(conn, idParent, 1000)
	if err != nil {
		t.Fatalf("MarkDone: %v", err)
	}
	if n != 3 {
		t.Errorf("MarkDone changed %d sessions, want 3", n)
	}
	for _, id := range []string{idParent, idChild, idGrand} {
		if at := doneAt(t, conn, id); at.Int64 != 1000 {
			t.Errorf("%s done_at = %v, want 1000", id[:8], at)
		}
	}
	if doneAt(t, conn, idOther).Valid {
		t.Error("an unrelated session was marked done")
	}
}

// Links can form a cycle (a re-delegation that points back up); the walk must
// still end, and mark each session once.
func TestMarkDone_CycleTerminates(t *testing.T) {
	conn := openTest(t)
	insertSession(t, conn, idParent, "")
	insertSession(t, conn, idChild, "")
	_ = LinkSession(conn, "bbbbbbbb", idParent)
	_ = LinkSession(conn, "aaaaaaaa", idChild)

	n, err := MarkDone(conn, idParent, 1000)
	if err != nil {
		t.Fatalf("MarkDone: %v", err)
	}
	if n != 2 {
		t.Errorf("MarkDone changed %d, want 2", n)
	}
}

// A done keeps its first time, the one GC ages: a repeat neither moves
// it nor counts it, but a descendant still open under it is caught.
func TestMarkDone_KeepsEarlierDoneAt(t *testing.T) {
	conn := openTest(t)
	insertSession(t, conn, idParent, "")
	insertSession(t, conn, idChild, "")
	_ = LinkSession(conn, "bbbbbbbb", idParent)
	if _, err := conn.Exec("UPDATE sessions SET done_at = 500 WHERE session_id = ?", idParent); err != nil {
		t.Fatal(err)
	}

	n, err := MarkDone(conn, idParent, 1000)
	if err != nil {
		t.Fatalf("MarkDone: %v", err)
	}
	if n != 1 {
		t.Errorf("MarkDone changed %d, want 1 (the child only)", n)
	}
	if at := doneAt(t, conn, idParent); at.Int64 != 500 {
		t.Errorf("parent done_at = %v, want the earlier 500", at)
	}
	if at := doneAt(t, conn, idChild); at.Int64 != 1000 {
		t.Errorf("child done_at = %v, want 1000", at)
	}
}

// A gone session is open work, however long ago its process ended.
func TestGC_KeepsGoneOpen(t *testing.T) {
	conn := openTest(t)
	insertSession(t, conn, "gone", "%1")
	insertEvent(t, conn, "gone", "SessionEnd", "ended", 30*day)
	terminate(t, conn, "gone", 30*day)

	if err := GC(conn, 7*day); err != nil {
		t.Fatalf("GC: %v", err)
	}
	if sessionCount(t, conn, "gone") != 1 {
		t.Error("GC deleted a gone (open) session")
	}
}

func TestGC_DeletesOldDone(t *testing.T) {
	conn := openTest(t)
	insertSession(t, conn, "old", "%1")
	insertEvent(t, conn, "old", "SessionEnd", "ended", 8*day)
	terminate(t, conn, "old", 8*day)
	setDone(t, conn, "old", 8*day)

	insertSession(t, conn, "recent", "%2")
	insertEvent(t, conn, "recent", "SessionEnd", "ended", 100)
	setDone(t, conn, "recent", 100)

	if err := GC(conn, 7*day); err != nil {
		t.Fatalf("GC: %v", err)
	}
	if sessionCount(t, conn, "old") != 0 {
		t.Error("old done session survived GC")
	}
	var n int
	_ = conn.QueryRow("SELECT COUNT(*) FROM events WHERE session_id = 'old'").Scan(&n)
	if n != 0 {
		t.Errorf("old done session's events survived GC: %d", n)
	}
	if sessionCount(t, conn, "recent") != 1 {
		t.Error("recently done session was deleted")
	}
}

// A link is kept while either end is open, and dropped once both are done (or
// gone from the ledger) and it is old.
func TestGC_KeepsLinkWhileEitherSideOpen(t *testing.T) {
	conn := openTest(t)
	const (
		pOpen = "p0000000-open"
		pDone = "p1111111-done"
	)
	insertSession(t, conn, pOpen, "")
	insertSession(t, conn, pDone, "")
	setDone(t, conn, pDone, 30*day)

	insertSession(t, conn, "11111111-c", "") // open child of a done parent
	insertSession(t, conn, "22222222-c", "") // done child of an open parent
	setDone(t, conn, "22222222-c", 30*day)
	insertSession(t, conn, "33333333-c", "") // done child of a done parent
	setDone(t, conn, "33333333-c", 1)
	insertSession(t, conn, "55555555-c", "") // gone (open) child of a done parent
	terminate(t, conn, "55555555-c", 30*day)

	links := map[string]string{
		"11111111": pDone,
		"22222222": pOpen,
		"33333333": pDone,
		"44444444": pDone, // child never wrote a row
		"55555555": pDone,
		"66666666": pDone, // fresh, child has no row yet
	}
	for c, p := range links {
		if err := LinkSession(conn, c, p); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := conn.Exec("UPDATE session_links SET created_at = unixepoch() - 30 * 86400 WHERE child_short != '66666666'"); err != nil {
		t.Fatal(err)
	}

	if err := GC(conn, 7*day); err != nil {
		t.Fatalf("GC: %v", err)
	}
	want := map[string]bool{
		"11111111": true,
		"22222222": true,
		"33333333": false,
		"44444444": false,
		"55555555": true,
		"66666666": true,
	}
	for c, keep := range want {
		if got := linkParent(t, conn, c) != ""; got != keep {
			t.Errorf("link %s kept = %v, want %v", c, got, keep)
		}
	}
}

func TestResolveSessionID_Ambiguous(t *testing.T) {
	conn := openTest(t)
	insertSession(t, conn, "abcd1234-1111", "")
	insertSession(t, conn, "abcd1234-2222", "")
	insertSession(t, conn, "ffff0000-1111", "")

	if _, err := ResolveSessionID(conn, "abcd1234"); err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Errorf("ambiguous prefix: err = %v, want an ambiguity error", err)
	}
	if _, err := ResolveSessionID(conn, "99999999"); err == nil || !strings.Contains(err.Error(), "no session") {
		t.Errorf("unknown prefix: err = %v, want a not-found error", err)
	}
	if _, err := ResolveSessionID(conn, "ffff"); err == nil {
		t.Error("short prefix accepted")
	}
	if id, err := ResolveSessionID(conn, "abcd1234-2"); err != nil || id != "abcd1234-2222" {
		t.Errorf("longer prefix = %q, %v; want abcd1234-2222", id, err)
	}
	if id, err := ResolveSessionID(conn, "ffff0000"); err != nil || id != "ffff0000-1111" {
		t.Errorf("unique prefix = %q, %v", id, err)
	}
}

func TestDoneButRunning(t *testing.T) {
	conn := openTest(t)
	for id, kind := range map[string]string{"bg-done": KindBackground, "bg-open": KindBackground, "ia-done": KindInteractive, "bg-gone": KindBackground} {
		insertSession(t, conn, id, "")
		if _, err := conn.Exec("UPDATE sessions SET kind = ? WHERE session_id = ?", kind, id); err != nil {
			t.Fatal(err)
		}
	}
	setDone(t, conn, "bg-done", 1)
	setDone(t, conn, "ia-done", 1)
	setDone(t, conn, "bg-gone", 1)
	terminate(t, conn, "bg-gone", 1)

	got, err := DoneButRunning(conn)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].SessionID != "bg-done" {
		t.Errorf("DoneButRunning = %+v, want only bg-done", got)
	}
}

// The done list holds the sessions the GC has not aged out, most recently
// done first, each carrying its done time as the age; open sessions and ones
// past the window are left out.
func TestListDoneRows_WindowAndOrder(t *testing.T) {
	conn := openTest(t)
	for _, id := range []string{"open", "old", "recent", "older"} {
		insertSession(t, conn, id, "")
	}
	setDone(t, conn, "recent", 100)
	setDone(t, conn, "older", 6*day)
	setDone(t, conn, "old", 8*day)

	got, err := ListDoneRows(conn, 7*day)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, r := range got {
		ids = append(ids, r.SessionID)
		if r.EffectiveState != StateDone {
			t.Errorf("%s state = %q, want %q", r.SessionID, r.EffectiveState, StateDone)
		}
		if at := doneAt(t, conn, r.SessionID); r.CreatedAt != at.Int64 {
			t.Errorf("%s CreatedAt = %d, want its done_at %d", r.SessionID, r.CreatedAt, at.Int64)
		}
	}
	if strings.Join(ids, ",") != "recent,older" {
		t.Errorf("ListDoneRows = %v, want [recent older]", ids)
	}
}

// Reopen clears done_at and reports whether it did.
func TestReopen(t *testing.T) {
	conn := openTest(t)
	insertSession(t, conn, "s", "")
	if ok, err := Reopen(conn, "s"); err != nil || ok {
		t.Errorf("Reopen of an open session = %v, %v; want false", ok, err)
	}
	setDone(t, conn, "s", 10)
	if ok, err := Reopen(conn, "s"); err != nil || !ok {
		t.Errorf("Reopen of a done session = %v, %v; want true", ok, err)
	}
	if at := doneAt(t, conn, "s"); at.Valid {
		t.Errorf("done_at = %v after Reopen, want NULL", at)
	}
}
