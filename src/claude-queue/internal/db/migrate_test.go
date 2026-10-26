package db

import (
	"database/sql"
	"path/filepath"
	"testing"
)

// migNow is the fixed clock the lifecycle migration tests run at.
const migNow int64 = 1_800_000_000

const day = 24 * 3600

// legacyLedger builds the fixture every lifecycle-migration test shares: one
// session per rule, written the way the pre-done_at hook wrote them, with the
// user_version reset so the migration has not run yet.
//
// Times are absolute, relative to migNow, because the migration is handed its
// clock rather than reading unixepoch().
func legacyLedger(t *testing.T, path string) {
	t.Helper()
	conn, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	type ev struct {
		sid, typ, state, payload string
		at                      int64
	}
	sessions := []struct {
		id, pane string
		termAt   int64 // 0 = live
	}{
		{"reboot", "%1", migNow - 2*day},      // rule 1: recent, reason other -> open
		{"reconciled", "%2", migNow - 1*day},  // rule 1: recent ForcedEnd, no clear after it -> open
		{"typedexit", "%3", migNow - 1*day},   // rule 1 excludes prompt_input_exit -> done
		{"cleared", "%4", migNow - 1*day},     // rule 1 excludes reason clear -> done
		{"forcedclear", "%5", migNow - 1*day}, // rule 2: ForcedEnd by a /clear in the same pane -> done
		{"clearnew", "%5", 0},                 // the session the /clear started
		{"forcedstart", "%6", migNow - 1*day}, // rule 2 negative: same-pane startup -> open
		{"startnew", "%6", 0},
		{"old", "%7", migNow - 30*day},          // rule 3: older than 7 days -> done
		{"resumedexit", "%8", migNow - 1*day},   // typed exit, resumed, then reconciled away -> open
		{"liveheld", "%9", 0},                   // rule 4: mark still on the latest event
		{"livelapsed", "%10", 0},                // rule 4: mark lapsed by a later event
		{"abcd1234-delegate", "", migNow - day}, // rule 5: linked -> background
	}
	for _, s := range sessions {
		var term any
		if s.termAt != 0 {
			term = s.termAt
		}
		var pane any
		if s.pane != "" {
			pane = s.pane
		}
		if _, err := conn.Exec("INSERT INTO sessions(session_id, tmux_pane, terminated_at) VALUES (?, ?, ?)", s.id, pane, term); err != nil {
			t.Fatalf("insert %s: %v", s.id, err)
		}
	}
	evs := []ev{
		{"reboot", "Stop", "idle_done", "", migNow - 2*day - 60},
		{"reboot", "SessionEnd", "ended", `{"reason":"other"}`, migNow - 2*day},
		{"reconciled", "UserPromptSubmit", "working", "", migNow - day - 60},
		{"reconciled", "ForcedEnd", "ended", "", migNow - day},
		{"typedexit", "SessionEnd", "ended", `{"reason":"prompt_input_exit"}`, migNow - day},
		{"cleared", "SessionEnd", "ended", `{"reason":"clear"}`, migNow - day},
		{"forcedclear", "Stop", "idle_done", "", migNow - day - 60},
		{"forcedclear", "ForcedEnd", "ended", "", migNow - day},
		{"clearnew", "SessionStart", "idle_done", `{"source":"clear"}`, migNow - day},
		{"forcedstart", "Stop", "idle_done", "", migNow - day - 60},
		{"forcedstart", "ForcedEnd", "ended", "", migNow - day},
		{"startnew", "SessionStart", "idle_done", `{"source":"startup"}`, migNow - day},
		{"old", "SessionEnd", "ended", `{"reason":"other"}`, migNow - 30*day},
		{"resumedexit", "SessionEnd", "ended", `{"reason":"prompt_input_exit"}`, migNow - 3*day},
		{"resumedexit", "SessionStart", "idle_done", `{"source":"resume"}`, migNow - 2*day},
		{"resumedexit", "ForcedEnd", "ended", "", migNow - day},
		{"liveheld", "Stop", "idle_done", "", migNow - 60},
		{"livelapsed", "Stop", "idle_done", "", migNow - 120},
		{"livelapsed", "UserPromptSubmit", "working", "", migNow - 60},
		{"abcd1234-delegate", "SessionEnd", "ended", `{"reason":"other"}`, migNow - day},
	}
	for _, e := range evs {
		var payload any
		if e.payload != "" {
			payload = e.payload
		}
		if _, err := conn.Exec(
			"INSERT INTO events(session_id, event_type, state, payload, created_at) VALUES (?, ?, ?, ?, ?)",
			e.sid, e.typ, e.state, payload, e.at,
		); err != nil {
			t.Fatalf("insert event %s/%s: %v", e.sid, e.typ, err)
		}
	}
	// Marks: liveheld on its only event, livelapsed on its first of two.
	if _, err := conn.Exec(`
		UPDATE sessions SET waiting_event_id = (SELECT MAX(id) FROM events WHERE session_id = 'liveheld') WHERE session_id = 'liveheld';
		UPDATE sessions SET waiting_event_id = (SELECT MIN(id) FROM events WHERE session_id = 'livelapsed') WHERE session_id = 'livelapsed';
		INSERT INTO session_links(child_short, parent_session_id) VALUES ('abcd1234', 'liveheld');
		UPDATE sessions SET kind = NULL;
		PRAGMA user_version = 0;
	`); err != nil {
		t.Fatalf("seed marks: %v", err)
	}
}

type migrated struct {
	DoneAt  sql.NullInt64
	Waiting sql.NullInt64
	Kind    sql.NullString
}

func snapshot(t *testing.T, conn *sql.DB) map[string]migrated {
	t.Helper()
	rows, err := conn.Query("SELECT session_id, done_at, waiting_event_id, kind FROM sessions")
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	defer rows.Close()
	out := map[string]migrated{}
	for rows.Next() {
		var id string
		var m migrated
		if err := rows.Scan(&id, &m.DoneAt, &m.Waiting, &m.Kind); err != nil {
			t.Fatal(err)
		}
		out[id] = m
	}
	return out
}

func migrateFixture(t *testing.T) map[string]migrated {
	t.Helper()
	path := filepath.Join(t.TempDir(), "m.db")
	legacyLedger(t, path)
	conn, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()
	// Open just ran the migration at the real clock; undo the stamp and run it
	// again at the fixed one. done_at is reset too, since that is all it wrote.
	if _, err := conn.Exec("UPDATE sessions SET done_at = NULL; PRAGMA user_version = 0"); err != nil {
		t.Fatal(err)
	}
	if err := migrateLifecycle(conn, migNow); err != nil {
		t.Fatalf("migrateLifecycle: %v", err)
	}
	return snapshot(t, conn)
}

func TestMigrateLifecycle_RecentNonExitEndStaysOpen(t *testing.T) {
	got := migrateFixture(t)
	for _, id := range []string{"reboot", "reconciled", "forcedstart", "resumedexit", "abcd1234-delegate"} {
		if got[id].DoneAt.Valid {
			t.Errorf("%s: done_at = %d, want NULL (open / gone)", id, got[id].DoneAt.Int64)
		}
	}
	for _, id := range []string{"liveheld", "livelapsed", "clearnew", "startnew"} {
		if got[id].DoneAt.Valid {
			t.Errorf("live session %s got done_at", id)
		}
	}
}

func TestMigrateLifecycle_ExitAndClearAreDone(t *testing.T) {
	got := migrateFixture(t)
	for _, id := range []string{"typedexit", "cleared"} {
		if got[id].DoneAt.Int64 != migNow-day {
			t.Errorf("%s: done_at = %v, want its terminated_at %d", id, got[id].DoneAt, migNow-day)
		}
	}
}

func TestMigrateLifecycle_ForcedEndByClearIsDone(t *testing.T) {
	got := migrateFixture(t)
	if got["forcedclear"].DoneAt.Int64 != migNow-day {
		t.Errorf("forcedclear: done_at = %v, want %d", got["forcedclear"].DoneAt, migNow-day)
	}
	if got["forcedstart"].DoneAt.Valid {
		t.Error("forcedstart (same-pane startup, not /clear) was made done")
	}
}

func TestMigrateLifecycle_OldIsDone(t *testing.T) {
	got := migrateFixture(t)
	if got["old"].DoneAt.Int64 != migNow-30*day {
		t.Errorf("old: done_at = %v, want %d", got["old"].DoneAt, migNow-30*day)
	}
}

func TestMigrateLifecycle_KeepsOnlyHeldMarks(t *testing.T) {
	got := migrateFixture(t)
	if !got["liveheld"].Waiting.Valid {
		t.Error("liveheld lost a mark that still held")
	}
	if got["livelapsed"].Waiting.Valid {
		t.Error("livelapsed kept a mark that had lapsed")
	}
}

func TestMigrateLifecycle_FillsKind(t *testing.T) {
	got := migrateFixture(t)
	if k := got["abcd1234-delegate"].Kind.String; k != KindBackground {
		t.Errorf("linked session kind = %q, want background", k)
	}
	if k := got["reboot"].Kind.String; k != KindInteractive {
		t.Errorf("unlinked session kind = %q, want interactive", k)
	}
}

// Open runs on every hook. The migration must run once and then leave the
// ledger alone, even when the clock has moved past the 7-day horizon of rows
// it kept open the first time.
func TestMigrate_Idempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "m.db")
	legacyLedger(t, path)

	conn, err := Open(path)
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	first := snapshot(t, conn)
	// Move every open row's end far into the past: a second migration pass
	// would now close them.
	if _, err := conn.Exec("UPDATE sessions SET terminated_at = terminated_at - 3650 * 86400 WHERE terminated_at IS NOT NULL AND done_at IS NULL"); err != nil {
		t.Fatal(err)
	}
	conn.Close()

	conn, err = Open(path)
	if err != nil {
		t.Fatalf("second Open: %v", err)
	}
	defer conn.Close()
	second := snapshot(t, conn)
	for id, a := range first {
		if b := second[id]; a != b {
			t.Errorf("%s changed on the second Open: %+v -> %+v", id, a, b)
		}
	}
	// Guard against a vacuous pass: the rows moved above must have been open.
	if first["reboot"].DoneAt.Valid {
		t.Fatal("fixture sanity: reboot should be open after the first Open")
	}
}
