package db

import (
	"database/sql"
	"path/filepath"
	"testing"
)

const legacyPR = "example-org/example-repo#7"

// writeLegacyPin stores a PR watch the way the binary before pr_watches did:
// in the session's pin_* columns, with the session pinned.
func writeLegacyPin(t *testing.T, conn *sql.DB, sid, pr string) {
	t.Helper()
	if _, err := conn.Exec(`
		UPDATE sessions
		SET waiting_event_id = 1, pin_note = 'waiting', pin_pr = ?2, pin_cursor = '2026-10-26T09:00:00Z',
		    pin_seen_at = 11, pin_delivered_at = 22, pin_delivered_upto = '2026-10-26T10:00:00Z',
		    pin_failures = 2, pin_halted_upto = '2026-10-26T11:00:00Z'
		WHERE session_id = ?1`, sid, pr); err != nil {
		t.Fatal(err)
	}
}

type legacyWatch struct {
	cursor, upTo, halted, note sql.NullString
	seen, delivered, failures  sql.NullInt64
}

func readWatch(t *testing.T, conn *sql.DB, sid, pr string) legacyWatch {
	t.Helper()
	var w legacyWatch
	if err := conn.QueryRow(`SELECT cursor, delivered_upto, halted_upto, note, seen_at, delivered_at, failures
		FROM pr_watches WHERE session_id = ? AND pr = ?`, sid, pr).
		Scan(&w.cursor, &w.upTo, &w.halted, &w.note, &w.seen, &w.delivered, &w.failures); err != nil {
		t.Fatalf("watch of %s: %v", sid, err)
	}
	return w
}

// assertUnpinned checks that every pin column of the session is NULL.
func assertUnpinned(t *testing.T, conn *sql.DB, sid string) {
	t.Helper()
	var n int
	if err := conn.QueryRow(`SELECT COUNT(*) FROM sessions WHERE session_id = ?
		AND waiting_event_id IS NULL AND pin_note IS NULL AND pin_pr IS NULL AND pin_cursor IS NULL
		AND pin_seen_at IS NULL AND pin_delivered_at IS NULL AND pin_delivered_upto IS NULL
		AND pin_failures IS NULL AND pin_halted_upto IS NULL`, sid).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("%s: pin columns not all cleared", sid)
	}
}

func reopen(t *testing.T, path string) *sql.DB {
	t.Helper()
	conn, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

// A PR watch kept on the pin moves to pr_watches with all of its state and its
// note, and the pin comes off. A plain pin, which watches nothing, stays.
func TestMigratePRWatches_MovesStateAndUnpins(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	conn := reopen(t, path)
	for _, id := range []string{"watched", "plain"} {
		insertSession(t, conn, id, "")
		insertEvent(t, conn, id, "Stop", "idle_done", 10)
	}
	writeLegacyPin(t, conn, "watched", legacyPR)
	note := "by hand"
	if err := SetPin(conn, "plain", &note); err != nil {
		t.Fatal(err)
	}
	conn.Close()

	conn = reopen(t, path)
	want := legacyWatch{
		cursor:    sql.NullString{String: "2026-10-26T09:00:00Z", Valid: true},
		upTo:      sql.NullString{String: "2026-10-26T10:00:00Z", Valid: true},
		halted:    sql.NullString{String: "2026-10-26T11:00:00Z", Valid: true},
		note:      sql.NullString{String: "waiting", Valid: true},
		seen:      sql.NullInt64{Int64: 11, Valid: true},
		delivered: sql.NullInt64{Int64: 22, Valid: true},
		failures:  sql.NullInt64{Int64: 2, Valid: true},
	}
	if got := readWatch(t, conn, "watched", legacyPR); got != want {
		t.Errorf("watch = %+v, want %+v", got, want)
	}
	assertUnpinned(t, conn, "watched")
	if _, got, pinned := annotationsOf(t, conn, "plain"); !pinned || got.String != note {
		t.Errorf("plain pin: pinned=%v note=%v", pinned, got)
	}
	var n int
	if err := conn.QueryRow("SELECT COUNT(*) FROM pr_watches").Scan(&n); err != nil || n != 1 {
		t.Errorf("watches = %d, %v; a plain pin must not become one", n, err)
	}
}

// Opening again changes nothing: not a watch that has since moved on, and not a
// pin put on after the move.
func TestMigratePRWatches_Idempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	conn := reopen(t, path)
	insertSession(t, conn, "a", "")
	insertEvent(t, conn, "a", "Stop", "idle_done", 10)
	writeLegacyPin(t, conn, "a", legacyPR)
	conn.Close()

	conn = reopen(t, path)
	if _, err := conn.Exec("UPDATE pr_watches SET failures = 9"); err != nil {
		t.Fatal(err)
	}
	if err := SetPin(conn, "a", nil); err != nil {
		t.Fatal(err)
	}
	conn.Close()

	conn = reopen(t, path)
	if got := readWatch(t, conn, "a", legacyPR); got.failures.Int64 != 9 {
		t.Errorf("a second Open rewrote the watch: %+v", got)
	}
	if _, _, pinned := annotationsOf(t, conn, "a"); !pinned {
		t.Error("a second Open took off a pin put on after the move")
	}
}

// A binary from before the move can still write pin_pr until it is rebuilt; the
// next Open picks that up, and leaves a watch already on that PR as it is.
func TestMigratePRWatches_PicksUpLaterWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	conn := reopen(t, path)
	insertSession(t, conn, "a", "")
	insertEvent(t, conn, "a", "Stop", "idle_done", 10)
	if _, err := conn.Exec("INSERT INTO pr_watches(session_id, pr, failures) VALUES ('a', 'example-org/example-repo#8', 9)"); err != nil {
		t.Fatal(err)
	}
	writeLegacyPin(t, conn, "a", legacyPR)
	conn.Close()
	conn = reopen(t, path)
	readWatch(t, conn, "a", legacyPR)
	assertUnpinned(t, conn, "a")

	writeLegacyPin(t, conn, "a", "example-org/example-repo#8")
	conn.Close()
	conn = reopen(t, path)
	if got := readWatch(t, conn, "a", "example-org/example-repo#8"); got.failures.Int64 != 9 {
		t.Errorf("the existing watch was overwritten: %+v", got)
	}
	assertUnpinned(t, conn, "a")
}

// A ledger written before pr_watches existed gains the table on Open.
func TestMigratePRWatches_CreatesTable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	conn := reopen(t, path)
	insertSession(t, conn, "a", "")
	insertEvent(t, conn, "a", "Stop", "idle_done", 10)
	writeLegacyPin(t, conn, "a", legacyPR)
	if _, err := conn.Exec("DROP TABLE pr_watches"); err != nil {
		t.Fatal(err)
	}
	conn.Close()
	conn = reopen(t, path)
	readWatch(t, conn, "a", legacyPR)
	assertUnpinned(t, conn, "a")
}
