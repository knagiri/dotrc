package done

import (
	"bytes"
	"path/filepath"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// The CLI is idempotent: a second run succeeds and changes nothing.
func TestDoneCLI_Idempotent(t *testing.T) {
	conn, err := db.Open(filepath.Join(t.TempDir(), "d.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	for _, id := range []string{"aaaaaaaa-1111", "bbbbbbbb-1111"} {
		if _, err := conn.Exec("INSERT INTO sessions(session_id) VALUES (?)", id); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.LinkSession(conn, "bbbbbbbb", "aaaaaaaa-1111"); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	if err := run(conn, "aaaaaaaa", 1000, &out); err != nil {
		t.Fatalf("first run: %v", err)
	}
	if got, want := out.String(), "done: aaaaaaaa-1111 (+1 descendants)\n"; got != want {
		t.Errorf("first output = %q, want %q", got, want)
	}
	out.Reset()
	if err := run(conn, "aaaaaaaa", 2000, &out); err != nil {
		t.Fatalf("second run: %v", err)
	}
	if got, want := out.String(), "done: aaaaaaaa-1111 (+0 descendants)\n"; got != want {
		t.Errorf("second output = %q, want %q", got, want)
	}
	var at int64
	_ = conn.QueryRow("SELECT done_at FROM sessions WHERE session_id = 'aaaaaaaa-1111'").Scan(&at)
	if at != 1000 {
		t.Errorf("done_at = %d after the repeat, want the first 1000", at)
	}
}

func TestDoneCLI_UnknownIDFails(t *testing.T) {
	conn, err := db.Open(filepath.Join(t.TempDir(), "d.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := run(conn, "12345678", 1, &bytes.Buffer{}); err == nil {
		t.Error("unknown id succeeded")
	}
}
