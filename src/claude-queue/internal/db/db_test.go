package db

import (
	"database/sql"
	"path/filepath"
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

func TestListRows_SortsByPriorityThenRecency(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "w", "%1")
	insertSession(t, conn, "i", "%2")
	insertSession(t, conn, "p", "%3")

	insertEvent(t, conn, "w", "UserPromptSubmit", "working", 60)
	insertEvent(t, conn, "i", "Stop", "idle_done", 60)
	insertEvent(t, conn, "p", "PermissionRequest", "awaiting_approval", 60)

	rows, err := ListRows(conn, ListOpts{})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("len(rows) = %d, want 2 (working filtered by default)", len(rows))
	}
	if rows[0].SessionID != "p" {
		t.Errorf("rows[0] = %q, want p (awaiting_approval first)", rows[0].SessionID)
	}
	if rows[1].SessionID != "i" {
		t.Errorf("rows[1] = %q, want i", rows[1].SessionID)
	}
}

func TestGC_DeletesOldEndedSessions(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "old", "%1")
	_, err = conn.Exec("UPDATE sessions SET terminated_at = unixepoch() - 700000 WHERE session_id = 'old'")
	if err != nil {
		t.Fatalf("update terminated: %v", err)
	}
	insertEvent(t, conn, "old", "SessionEnd", "ended", 700000)

	insertSession(t, conn, "recent", "%2")
	_, _ = conn.Exec("UPDATE sessions SET terminated_at = unixepoch() - 100 WHERE session_id = 'recent'")
	insertEvent(t, conn, "recent", "SessionEnd", "ended", 100)

	if err := GC(conn, 7*24*3600); err != nil {
		t.Fatalf("GC: %v", err)
	}

	var n int
	_ = conn.QueryRow("SELECT COUNT(*) FROM sessions WHERE session_id = 'old'").Scan(&n)
	if n != 0 {
		t.Errorf("old session should be deleted; count = %d", n)
	}
	_ = conn.QueryRow("SELECT COUNT(*) FROM sessions WHERE session_id = 'recent'").Scan(&n)
	if n != 1 {
		t.Errorf("recent session should be kept; count = %d", n)
	}
}
