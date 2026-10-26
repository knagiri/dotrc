package db

import (
	"database/sql"
	"path/filepath"
	"testing"
)

func openTest(t *testing.T) *sql.DB {
	t.Helper()
	conn, err := Open(filepath.Join(t.TempDir(), "q.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

// findRow returns sid's row in the full listing, and whether it is there.
func findRow(t *testing.T, conn *sql.DB, sid string) (Row, bool) {
	t.Helper()
	rows, err := ListRows(conn, ListOpts{ShowWorking: true, ShowStale: true})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	for _, r := range rows {
		if r.SessionID == sid {
			return r, true
		}
	}
	return Row{}, false
}

// A session whose process ended without its work being declared done -- the
// SessionEnd(reason=other) a host shutdown sends -- stays listed as gone,
// carrying what it was doing and sorted behind the running rows.
func TestQueueView_GoneStaysListed(t *testing.T) {
	conn := openTest(t)
	insertSession(t, conn, "g", "%1")
	insertEvent(t, conn, "g", "SessionStart", "idle_done", 300)
	insertEvent(t, conn, "g", "Stop", "idle_done", 200)
	insertEventPayload(t, conn, "g", "SessionEnd", "ended", `{"reason":"other"}`, 100)
	terminate(t, conn, "g", 100)

	r, ok := findRow(t, conn, "g")
	if !ok {
		t.Fatal("gone session not listed")
	}
	if r.EffectiveState != StateGone || r.PriorState.String != "idle_done" || r.Priority != 7 {
		t.Errorf("row = {%q, prior %q, prio %d}, want {gone, idle_done, 7}", r.EffectiveState, r.PriorState.String, r.Priority)
	}
	// The recorded pane names a process that has ended; it must not be offered.
	if r.TmuxPane.Valid {
		t.Errorf("gone row carries pane %q", r.TmuxPane.String)
	}
}

// Cut off mid-task sorts ahead of finished-a-turn among the gone rows.
func TestQueueView_GoneInterruptedSortsFirst(t *testing.T) {
	conn := openTest(t)
	insertSession(t, conn, "w", "%1")
	insertEvent(t, conn, "w", "UserPromptSubmit", "working", 200)
	insertEvent(t, conn, "w", "ForcedEnd", "ended", 100)
	terminate(t, conn, "w", 100)

	r, ok := findRow(t, conn, "w")
	if !ok || r.Priority != 6 || r.PriorState.String != "working" {
		t.Errorf("row = %+v (listed %v), want priority 6, prior working", r, ok)
	}
}

func TestQueueView_DoneIsHidden(t *testing.T) {
	conn := openTest(t)
	insertSession(t, conn, "d", "%1")
	insertEvent(t, conn, "d", "Stop", "idle_done", 100)
	if _, err := conn.Exec("UPDATE sessions SET done_at = unixepoch() WHERE session_id = 'd'"); err != nil {
		t.Fatal(err)
	}
	if _, ok := findRow(t, conn, "d"); ok {
		t.Error("done session is listed")
	}
}
