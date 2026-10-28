package reopen

import (
	"bytes"
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

func openDB(t *testing.T) *sql.DB {
	t.Helper()
	conn, err := db.Open(filepath.Join(t.TempDir(), "r.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func isDone(t *testing.T, conn *sql.DB, id string) bool {
	t.Helper()
	var done bool
	if err := conn.QueryRow("SELECT done_at IS NOT NULL FROM sessions WHERE session_id = ?", id).Scan(&done); err != nil {
		t.Fatal(err)
	}
	return done
}

// reopen clears the done of the session named, and only of it: the delegate
// the done cascaded to stays done.
func TestReopenCLI_ClearsDoneWithoutCascade(t *testing.T) {
	conn := openDB(t)
	for _, id := range []string{"aaaaaaaa-1111", "bbbbbbbb-1111"} {
		if _, err := conn.Exec("INSERT INTO sessions(session_id) VALUES (?)", id); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.LinkSession(conn, "bbbbbbbb", "aaaaaaaa-1111"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.MarkDone(conn, "aaaaaaaa-1111", 1000); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	if err := run(conn, "aaaaaaaa", &out); err != nil {
		t.Fatalf("reopen: %v", err)
	}
	if got, want := out.String(), "reopened: aaaaaaaa-1111\n"; got != want {
		t.Errorf("output = %q, want %q", got, want)
	}
	if isDone(t, conn, "aaaaaaaa-1111") {
		t.Error("reopened session is still done")
	}
	if !isDone(t, conn, "bbbbbbbb-1111") {
		t.Error("reopen cascaded to the delegate")
	}
}

// A session that is not done, and an id that names no session, both fail.
func TestReopenCLI_NotDoneOrUnknownFails(t *testing.T) {
	conn := openDB(t)
	if _, err := conn.Exec("INSERT INTO sessions(session_id) VALUES ('aaaaaaaa-1111')"); err != nil {
		t.Fatal(err)
	}
	if err := run(conn, "aaaaaaaa", &bytes.Buffer{}); err == nil {
		t.Error("reopening an open session succeeded")
	}
	if err := run(conn, "12345678", &bytes.Buffer{}); err == nil {
		t.Error("unknown id succeeded")
	}
}

// Done again after a reopen, the session is aged from the new done -- the
// GC's clock restarts rather than collecting it on the first done's schedule.
func TestReopen_RedoneAgesFromNewTime(t *testing.T) {
	conn := openDB(t)
	if _, err := conn.Exec("INSERT INTO sessions(session_id) VALUES ('aaaaaaaa-1111')"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.MarkDone(conn, "aaaaaaaa-1111", 1000); err != nil {
		t.Fatal(err)
	}
	if err := run(conn, "aaaaaaaa", &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if _, err := db.MarkDone(conn, "aaaaaaaa-1111", 2000); err != nil {
		t.Fatal(err)
	}
	var at int64
	if err := conn.QueryRow("SELECT done_at FROM sessions WHERE session_id = 'aaaaaaaa-1111'").Scan(&at); err != nil {
		t.Fatal(err)
	}
	if at != 2000 {
		t.Errorf("done_at = %d, want the new 2000", at)
	}
}
