package db

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenAppliesSchemaAndPragmas(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")

	conn, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	var jm string
	if err := conn.QueryRow("PRAGMA journal_mode").Scan(&jm); err != nil {
		t.Fatalf("journal_mode pragma: %v", err)
	}
	if jm != "wal" {
		t.Errorf("journal_mode = %q, want %q", jm, "wal")
	}

	// sessions / events / queue should exist.
	wantObjects := []string{"sessions", "events", "queue"}
	for _, name := range wantObjects {
		var got string
		err := conn.QueryRow(
			"SELECT name FROM sqlite_master WHERE name = ?", name,
		).Scan(&got)
		if err != nil {
			t.Errorf("object %q not found: %v", name, err)
		}
	}
}

func TestOpenIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")

	for i := 0; i < 3; i++ {
		conn, err := Open(path)
		if err != nil {
			t.Fatalf("Open iter %d: %v", i, err)
		}
		conn.Close()
	}
}

func insertSession(t *testing.T, conn *sql.DB, id, pane string) {
	t.Helper()
	_, err := conn.Exec(
		"INSERT INTO sessions(session_id, tmux_pane) VALUES (?, ?)", id, pane,
	)
	if err != nil {
		t.Fatalf("insert session: %v", err)
	}
}

func insertEvent(t *testing.T, conn *sql.DB, sid, evType, state string, agoSec int64) {
	t.Helper()
	_, err := conn.Exec(
		"INSERT INTO events(session_id, event_type, state, created_at) VALUES (?, ?, ?, unixepoch() - ?)",
		sid, evType, state, agoSec,
	)
	if err != nil {
		t.Fatalf("insert event: %v", err)
	}
}

func insertEventPayload(t *testing.T, conn *sql.DB, sid, evType, state, payload string, agoSec int64) {
	t.Helper()
	_, err := conn.Exec(
		"INSERT INTO events(session_id, event_type, state, payload, created_at) VALUES (?, ?, ?, ?, unixepoch() - ?)",
		sid, evType, state, payload, agoSec,
	)
	if err != nil {
		t.Fatalf("insert event: %v", err)
	}
}

func terminate(t *testing.T, conn *sql.DB, sid string, agoSec int64) {
	t.Helper()
	_, err := conn.Exec(
		"UPDATE sessions SET terminated_at = unixepoch() - ? WHERE session_id = ?", agoSec, sid,
	)
	if err != nil {
		t.Fatalf("terminate %s: %v", sid, err)
	}
}

func TestCounts(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "a", "%1")
	insertSession(t, conn, "b", "%2")
	insertSession(t, conn, "c", "%3")
	insertEvent(t, conn, "a", "PermissionRequest", "awaiting_approval", 5)
	insertEvent(t, conn, "b", "Stop", "idle_done", 10)
	insertEvent(t, conn, "c", "UserPromptSubmit", "working", 3)

	got, err := Counts(conn)
	if err != nil {
		t.Fatalf("Counts: %v", err)
	}
	if got["awaiting_approval"] != 1 {
		t.Errorf("awaiting_approval = %d, want 1", got["awaiting_approval"])
	}
	if got["idle_done"] != 1 {
		t.Errorf("idle_done = %d, want 1", got["idle_done"])
	}
	if got["working"] != 1 {
		t.Errorf("working = %d, want 1", got["working"])
	}
}

// The listing is one order -- newest activity first -- with no tier per state.
// A hibernated session ranks by what it last did, not by when it was stopped,
// and awaiting_approval does not jump ahead of newer activity.
func TestListRows_SortsByActivity(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	for i, sid := range []string{"wnew", "i", "g", "wold", "p"} {
		insertSession(t, conn, sid, fmt.Sprintf("%%%d", i))
	}
	insertEvent(t, conn, "wnew", "UserPromptSubmit", "working", 100)
	insertEvent(t, conn, "i", "Stop", "idle_done", 250)
	// Put to sleep: its last activity is 300s ago, its end only 10s ago.
	insertEvent(t, conn, "g", "Stop", "idle_done", 300)
	insertEventPayload(t, conn, "g", "SessionEnd", "ended", `{"reason":"other"}`, 10)
	terminate(t, conn, "g", 10)
	insertEvent(t, conn, "wold", "UserPromptSubmit", "working", 400)
	insertEvent(t, conn, "p", "PermissionRequest", "awaiting_approval", 500)

	rows, err := ListRows(conn, ListOpts{ShowWorking: true})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	var got []string
	for _, r := range rows {
		got = append(got, r.SessionID)
	}
	want := []string{"wnew", "i", "g", "wold", "p"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("order = %v, want %v", got, want)
	}
}

// With no non-ended event at all, activity falls back to the latest event.
func TestListRows_ActivityFallsBackToLatestEvent(t *testing.T) {
	conn := openTest(t)
	insertSession(t, conn, "e", "%1")
	insertEvent(t, conn, "e", "SessionEnd", "ended", 10)
	terminate(t, conn, "e", 10)

	r, ok := findRow(t, conn, "e")
	if !ok {
		t.Fatal("session not listed")
	}
	if r.ActivityAt == 0 || r.ActivityAt != r.CreatedAt {
		t.Errorf("ActivityAt = %d, want CreatedAt %d", r.ActivityAt, r.CreatedAt)
	}
}

func TestTerminateSession(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "s", "%1")
	insertEvent(t, conn, "s", "PermissionRequest", "awaiting_approval", 5)

	if err := TerminateSession(conn, "s"); err != nil {
		t.Fatalf("TerminateSession: %v", err)
	}

	var terminated int64
	_ = conn.QueryRow(
		"SELECT COALESCE(terminated_at, 0) FROM sessions WHERE session_id = ?", "s",
	).Scan(&terminated)
	if terminated == 0 {
		t.Error("terminated_at should be set")
	}

	var n int
	_ = conn.QueryRow(
		"SELECT COUNT(*) FROM events WHERE session_id = 's' AND event_type = 'ForcedEnd'",
	).Scan(&n)
	if n != 1 {
		t.Errorf("expected 1 ForcedEnd event, got %d", n)
	}

	// The process axis only: the session stays listed, as gone.
	rows, err := ListRows(conn, ListOpts{ShowWorking: true})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	if len(rows) != 1 || rows[0].EffectiveState != StateGone {
		t.Errorf("ListRows after Terminate = %+v, want one gone row", rows)
	}
}

func linkParent(t *testing.T, conn *sql.DB, childID string) string {
	t.Helper()
	var p sql.NullString
	err := conn.QueryRow(
		"SELECT parent_session_id FROM session_links WHERE child_short = ?", childID,
	).Scan(&p)
	if err == sql.ErrNoRows {
		return ""
	}
	if err != nil {
		t.Fatalf("read link %s: %v", childID, err)
	}
	return p.String
}

// Re-linking a child replaces its parent rather than failing on the primary
// key or keeping the first one: a worktree re-delegated from another session
// belongs to the new delegator.
func TestLinkSession_Upsert(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "l.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	if err := LinkSession(conn, "abcd1234", "parent-one"); err != nil {
		t.Fatalf("LinkSession: %v", err)
	}
	// Age the first link so the upsert has a created_at to restart.
	if _, err := conn.Exec("UPDATE session_links SET created_at = unixepoch() - 1000"); err != nil {
		t.Fatalf("age link: %v", err)
	}
	if err := LinkSession(conn, "abcd1234", "parent-two"); err != nil {
		t.Fatalf("LinkSession relink: %v", err)
	}
	if got := linkParent(t, conn, "abcd1234"); got != "parent-two" {
		t.Errorf("parent = %q, want parent-two", got)
	}
	var n, age int64
	_ = conn.QueryRow("SELECT COUNT(*), MAX(unixepoch() - created_at) FROM session_links").Scan(&n, &age)
	if n != 1 {
		t.Errorf("links = %d, want 1", n)
	}
	if age > 10 {
		t.Errorf("relink kept the old created_at (age %ds)", age)
	}
}

// ListRows joins a link on the 8-char prefix of the row's full id, and a row
// with no link comes back NULL rather than empty.
func TestListRows_JoinsParent(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "j.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "abcd1234-1111-2222-3333-444444444444", "%1")
	insertSession(t, conn, "ffff0000-1111-2222-3333-444444444444", "%2")
	insertEvent(t, conn, "abcd1234-1111-2222-3333-444444444444", "Stop", "idle_done", 5)
	insertEvent(t, conn, "ffff0000-1111-2222-3333-444444444444", "Stop", "idle_done", 5)
	if err := LinkSession(conn, "abcd1234", "parent-uuid"); err != nil {
		t.Fatalf("LinkSession: %v", err)
	}

	rows, err := ListRows(conn, ListOpts{})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	got := map[string]sql.NullString{}
	for _, r := range rows {
		got[r.SessionID] = r.ParentSessionID
	}
	if p := got["abcd1234-1111-2222-3333-444444444444"]; !p.Valid || p.String != "parent-uuid" {
		t.Errorf("linked row parent = %+v, want parent-uuid", p)
	}
	if p, ok := got["ffff0000-1111-2222-3333-444444444444"]; !ok || p.Valid {
		t.Errorf("unlinked row parent = %+v (present %v), want NULL", p, ok)
	}
}

// ListOpts.Includes is the filter the picker applies to rows it read unfiltered,
// so it has to agree with what the flags meant when ListRows filtered in SQL.
func TestListOptsIncludes(t *testing.T) {
	states := []string{"awaiting_approval", "idle_done", "working", StateGone}
	cases := []struct {
		opts ListOpts
		want []bool
	}{
		{ListOpts{}, []bool{true, true, false, true}},
		{ListOpts{ShowWorking: true}, []bool{true, true, true, true}},
	}
	for _, tc := range cases {
		for i, s := range states {
			if got := tc.opts.Includes(s); got != tc.want[i] {
				t.Errorf("%+v.Includes(%q) = %v, want %v", tc.opts, s, got, tc.want[i])
			}
		}
	}
}

// The migration exists because CREATE TABLE IF NOT EXISTS is a no-op on an
// existing database: without it, every ledger already on disk would stay one
// column short forever and every row in it would keep being matched against the
// wrong config dir's roster.
//
// The fixture is a sessions table in its pre-migration shape, which is why the
// DDL is written out here rather than derived from Tables -- deriving it would
// make the test follow the schema it is supposed to be pinning.
func TestOpenMigratesAnExistingDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")

	old, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	if _, err := old.Exec(`
		CREATE TABLE sessions (
		  session_id      TEXT PRIMARY KEY,
		  tmux_pane       TEXT,
		  cwd             TEXT,
		  transcript_path TEXT,
		  started_at      INTEGER NOT NULL DEFAULT (unixepoch()),
		  terminated_at   INTEGER
		);
		INSERT INTO sessions(session_id, cwd) VALUES ('legacy', '/w/a');
	`); err != nil {
		t.Fatalf("seed pre-migration database: %v", err)
	}
	old.Close()

	conn, err := Open(path)
	if err != nil {
		t.Fatalf("Open on a pre-migration database: %v", err)
	}
	defer conn.Close()

	// The column is there, the pre-existing row survived, and its config_dir is
	// NULL -- which ConfigDirOf reads as the default.
	var dir sql.NullString
	if err := conn.QueryRow("SELECT config_dir FROM sessions WHERE session_id = 'legacy'").Scan(&dir); err != nil {
		t.Fatalf("read migrated column: %v", err)
	}
	if dir.Valid {
		t.Errorf("config_dir = %q, want NULL on a row written before the column existed", dir.String)
	}
	if got := ConfigDirOf(dir); got == "" {
		t.Error("ConfigDirOf(NULL) = \"\", want the default dir")
	}

	// waiting_event_id came in the same way, and the queue view that selects it
	// has to be creatable on the migrated table.
	var mark sql.NullInt64
	if err := conn.QueryRow("SELECT waiting_event_id FROM sessions WHERE session_id = 'legacy'").Scan(&mark); err != nil {
		t.Fatalf("read migrated waiting_event_id: %v", err)
	}
	if mark.Valid {
		t.Errorf("waiting_event_id = %d, want NULL on a row written before the column existed", mark.Int64)
	}

	// And the whole thing is idempotent: Open runs on every hook invocation, so
	// a migration that fails the second time would take the ledger down with it.
	conn2, err := Open(path)
	if err != nil {
		t.Fatalf("second Open: %v", err)
	}
	conn2.Close()
}

// The view has to select the column too, or the picker reads every row as the
// default dir no matter what the hook recorded.
func TestQueueViewCarriesConfigDir(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	if _, err := conn.Exec(
		"INSERT INTO sessions(session_id, config_dir) VALUES ('s1', '/home/x/.claude-personal')",
	); err != nil {
		t.Fatalf("insert session: %v", err)
	}
	if _, err := conn.Exec(
		"INSERT INTO events(session_id, event_type, state) VALUES ('s1', 'Stop', 'idle_done')",
	); err != nil {
		t.Fatalf("insert event: %v", err)
	}

	rows, err := ListRows(conn, ListOpts{})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("len(rows) = %d, want 1", len(rows))
	}
	if got := ConfigDirOf(rows[0].ConfigDir); got != "/home/x/.claude-personal" {
		t.Errorf("row config dir = %q, want /home/x/.claude-personal", got)
	}

	dirs, err := RecordedConfigDirs(conn)
	if err != nil {
		t.Fatalf("RecordedConfigDirs: %v", err)
	}
	if len(dirs) != 1 || dirs[0] != "/home/x/.claude-personal" {
		t.Errorf("RecordedConfigDirs = %v, want [/home/x/.claude-personal]", dirs)
	}
}

// markedOf returns the Marked flag ListRows reports for sid.
func markedOf(t *testing.T, conn *sql.DB, sid string) bool {
	t.Helper()
	rows, err := ListRows(conn, ListOpts{ShowWorking: true})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	for _, r := range rows {
		if r.SessionID == sid {
			return r.Marked
		}
	}
	t.Fatalf("session %s not listed", sid)
	return false
}

func TestToggleMark_SetsAndClears(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "m.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()
	insertSession(t, conn, "a", "%1")
	insertSession(t, conn, "b", "%2")
	insertEvent(t, conn, "a", "Stop", "idle_done", 10)
	insertEvent(t, conn, "b", "Stop", "idle_done", 10)

	if markedOf(t, conn, "a") {
		t.Fatal("a marked before any toggle")
	}
	on, err := ToggleMark(conn, "a")
	if err != nil || !on {
		t.Fatalf("first ToggleMark = %v, %v; want true, nil", on, err)
	}
	if !markedOf(t, conn, "a") {
		t.Error("a not marked after the first toggle")
	}
	if markedOf(t, conn, "b") {
		t.Error("b marked by a toggle on a")
	}
	off, err := ToggleMark(conn, "a")
	if err != nil || off {
		t.Fatalf("second ToggleMark = %v, %v; want false, nil", off, err)
	}
	if markedOf(t, conn, "a") {
		t.Error("a still marked after the second toggle")
	}
}

// The mark holds until it is toggled off: later hook events -- the session
// being nudged while it waits -- do not lift it.
func TestToggleMark_PersistsAcrossEvents(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "m.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()
	insertSession(t, conn, "a", "%1")
	insertEvent(t, conn, "a", "Stop", "idle_done", 10)

	if on, err := ToggleMark(conn, "a"); err != nil || !on {
		t.Fatalf("ToggleMark = %v, %v; want true, nil", on, err)
	}
	insertEvent(t, conn, "a", "UserPromptSubmit", "working", 5)
	insertEvent(t, conn, "a", "Stop", "idle_done", 0)
	if !markedOf(t, conn, "a") {
		t.Error("a new event lifted the mark")
	}
	if on, err := ToggleMark(conn, "a"); err != nil || on {
		t.Errorf("ToggleMark after events = %v, %v; want false (cleared), nil", on, err)
	}
}

// A gone session is open work: it can be marked, and keeps the mark.
func TestToggleMark_GoneSession(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "m.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()
	insertSession(t, conn, "g", "%1")
	insertEvent(t, conn, "g", "Stop", "idle_done", 20)
	insertEventPayload(t, conn, "g", "SessionEnd", "ended", `{"reason":"other"}`, 10)
	terminate(t, conn, "g", 10)

	if on, err := ToggleMark(conn, "g"); err != nil || !on {
		t.Fatalf("ToggleMark(gone) = %v, %v; want true, nil", on, err)
	}
	if !markedOf(t, conn, "g") {
		t.Error("gone session not shown marked")
	}
}

// The reboot case, end to end in the ledger: a marked delegate and its parent
// both lose their processes (a SessionEnd for one, a reconcile ForcedEnd for
// the other) and both stay listed, gone, with the mark and the link intact.
func TestListRows_GoneKeepsMarkAndParent(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "r.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()
	const parent, child = "aaaaaaaa-0000", "bbbbbbbb-0000"
	insertSession(t, conn, parent, "%1")
	insertSession(t, conn, child, "")
	insertEvent(t, conn, parent, "UserPromptSubmit", "working", 100)
	insertEvent(t, conn, child, "Stop", "idle_done", 100)
	if err := LinkSession(conn, "bbbbbbbb", parent); err != nil {
		t.Fatal(err)
	}
	if on, err := ToggleMark(conn, child); err != nil || !on {
		t.Fatalf("ToggleMark = %v, %v", on, err)
	}

	insertEventPayload(t, conn, parent, "SessionEnd", "ended", `{"reason":"other"}`, 10)
	terminate(t, conn, parent, 10)
	if err := TerminateSession(conn, child); err != nil {
		t.Fatal(err)
	}

	rows, err := ListRows(conn, ListOpts{})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]Row{}
	for _, r := range rows {
		got[r.SessionID] = r
	}
	p, ok := got[parent]
	if !ok || p.EffectiveState != StateGone {
		t.Errorf("parent = %+v (listed %v), want gone in the default listing", p, ok)
	}
	c, ok := got[child]
	if !ok || c.EffectiveState != StateGone {
		t.Fatalf("child = %+v (listed %v), want gone in the default listing", c, ok)
	}
	if !c.Marked {
		t.Error("child lost its mark")
	}
	if c.ParentSessionID.String != parent {
		t.Errorf("child parent = %+v, want %s", c.ParentSessionID, parent)
	}
}

// Marking changes the icon only: state, activity and order stay as they were.
func TestToggleMark_LeavesStateAndOrder(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "m.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()
	insertSession(t, conn, "p", "%1")
	insertSession(t, conn, "i", "%2")
	insertEvent(t, conn, "p", "PermissionRequest", "awaiting_approval", 60)
	insertEvent(t, conn, "i", "Stop", "idle_done", 60)

	before, err := ListRows(conn, ListOpts{})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	on, err := ToggleMark(conn, "i")
	if err != nil {
		t.Fatalf("ToggleMark: %v", err)
	}
	// Guard against a no-op ToggleMark: the mark must actually be applied,
	// otherwise the "unchanged" checks below prove nothing.
	if !on {
		t.Fatalf("ToggleMark(i) = false; want true")
	}
	after, err := ListRows(conn, ListOpts{})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	if len(before) != len(after) {
		t.Fatalf("row count %d -> %d", len(before), len(after))
	}
	for k := range before {
		b, a := before[k], after[k]
		if a.SessionID != b.SessionID || a.EffectiveState != b.EffectiveState || a.ActivityAt != b.ActivityAt {
			t.Errorf("row %d changed: %+v -> %+v", k, b, a)
		}
		if want := a.SessionID == "i"; a.Marked != want {
			t.Errorf("session %s Marked = %v; want %v", a.SessionID, a.Marked, want)
		}
	}
}

// A done session is not listed, so nothing should mark it; an id the ledger
// does not know is the same. Both are a silent no-op, not an error or a write.
func TestToggleMark_DoneOrUnknownIsNoop(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "m.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()
	insertSession(t, conn, "e", "%1")
	insertEvent(t, conn, "e", "SessionEnd", "ended", 10)
	terminate(t, conn, "e", 10)
	if _, err := conn.Exec("UPDATE sessions SET done_at = unixepoch() WHERE session_id = 'e'"); err != nil {
		t.Fatal(err)
	}

	for _, sid := range []string{"e", "nope"} {
		on, err := ToggleMark(conn, sid)
		if err != nil || on {
			t.Errorf("ToggleMark(%s) = %v, %v; want false, nil", sid, on, err)
		}
	}
	var mark sql.NullInt64
	if err := conn.QueryRow("SELECT waiting_event_id FROM sessions WHERE session_id = 'e'").Scan(&mark); err != nil {
		t.Fatalf("read: %v", err)
	}
	if mark.Valid {
		t.Errorf("done session got waiting_event_id = %d", mark.Int64)
	}
}
