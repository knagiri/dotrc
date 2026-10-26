package annotate

import (
	"bytes"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

const sid = "aaaaaaaa-1111"

func setup(t *testing.T) *sql.DB {
	t.Helper()
	conn, err := db.Open(filepath.Join(t.TempDir(), "a.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	if _, err := conn.Exec("INSERT INTO sessions(session_id) VALUES (?)", sid); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec("INSERT INTO events(session_id, event_type, state) VALUES (?, 'Stop', 'idle_done')", sid); err != nil {
		t.Fatal(err)
	}
	return conn
}

func env(vals map[string]string) func(string) string {
	return func(k string) string { return vals[k] }
}

func pinOf(t *testing.T, conn *sql.DB) (bool, sql.NullString) {
	t.Helper()
	var pinned bool
	var note sql.NullString
	if err := conn.QueryRow(
		"SELECT waiting_event_id IS NOT NULL, pin_note FROM sessions WHERE session_id = ?", sid,
	).Scan(&pinned, &note); err != nil {
		t.Fatal(err)
	}
	return pinned, note
}

func TestMemoCLI_PrintsCurrent(t *testing.T) {
	conn := setup(t)
	var out bytes.Buffer
	if err := run(conn, "memo", []string{"--session", "aaaaaaaa", "fix the build"}, env(nil), time.Now, &out, &out); err != nil {
		t.Fatalf("set: %v", err)
	}
	if out.Len() != 0 {
		t.Errorf("set printed %q", out.String())
	}
	if err := run(conn, "memo", []string{"--session", "aaaaaaaa"}, env(nil), time.Now, &out, &out); err != nil {
		t.Fatalf("print: %v", err)
	}
	if got, want := out.String(), "fix the build\n"; got != want {
		t.Errorf("printed %q, want %q", got, want)
	}
	out.Reset()
	if err := run(conn, "memo", []string{"--session", "aaaaaaaa", ""}, env(nil), time.Now, &out, &out); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if err := run(conn, "memo", []string{"--session", "aaaaaaaa"}, env(nil), time.Now, &out, &out); err != nil || out.Len() != 0 {
		t.Errorf("after clearing: printed %q, %v; want nothing", out.String(), err)
	}
}

func TestPinCLI_UsesEnvSessionID(t *testing.T) {
	conn := setup(t)
	e := env(map[string]string{sessionEnv: sid})
	var out bytes.Buffer
	if err := run(conn, "pin", []string{"--note", "waiting on review"}, e, time.Now, &out, &out); err != nil {
		t.Fatalf("pin: %v", err)
	}
	if pinned, note := pinOf(t, conn); !pinned || note.String != "waiting on review" {
		t.Errorf("pinned=%v note=%v", pinned, note)
	}
	// Without --note the note stays.
	if err := run(conn, "pin", nil, e, time.Now, &out, &out); err != nil {
		t.Fatalf("pin again: %v", err)
	}
	if _, note := pinOf(t, conn); note.String != "waiting on review" {
		t.Errorf("note = %v after a pin without --note", note)
	}
}

func TestPinCLI_NoIDNoEnv(t *testing.T) {
	conn := setup(t)
	var out, errOut bytes.Buffer
	err := run(conn, "pin", []string{"--note", "x"}, env(nil), time.Now, &out, &errOut)
	if !errors.Is(err, errUsage) {
		t.Fatalf("err = %v, want errUsage", err)
	}
	if pinned, _ := pinOf(t, conn); pinned {
		t.Error("pinned without a session id")
	}
}

func TestUnpinCLI(t *testing.T) {
	conn := setup(t)
	e := env(map[string]string{sessionEnv: sid})
	var out bytes.Buffer
	if err := run(conn, "pin", []string{"--note", "n"}, e, time.Now, &out, &out); err != nil {
		t.Fatal(err)
	}
	if err := run(conn, "unpin", nil, e, time.Now, &out, &out); err != nil {
		t.Fatalf("unpin: %v", err)
	}
	if pinned, note := pinOf(t, conn); pinned || note.Valid {
		t.Errorf("after unpin: pinned=%v note=%v", pinned, note)
	}
}

func TestCLI_DoneSessionFails(t *testing.T) {
	conn := setup(t)
	if _, err := conn.Exec("UPDATE sessions SET done_at = 1"); err != nil {
		t.Fatal(err)
	}
	e := env(map[string]string{sessionEnv: sid})
	var out bytes.Buffer
	if err := run(conn, "pin", nil, e, time.Now, &out, &out); !errors.Is(err, db.ErrDone) {
		t.Errorf("pin on done = %v, want ErrDone", err)
	}
}

func TestCLI_ExtraArgsAreUsage(t *testing.T) {
	conn := setup(t)
	e := env(map[string]string{sessionEnv: sid})
	var out bytes.Buffer
	for _, c := range []struct {
		cmd  string
		args []string
	}{
		{"memo", []string{"a", "b"}},
		{"pin", []string{"stray"}},
		{"unpin", []string{"stray"}},
	} {
		if err := run(conn, c.cmd, c.args, e, time.Now, &out, &out); !errors.Is(err, errUsage) {
			t.Errorf("%s %v = %v, want errUsage", c.cmd, c.args, err)
		}
	}
}

func TestMemoCLI_DashLeadingText(t *testing.T) {
	conn := setup(t)
	var out bytes.Buffer
	if err := run(conn, "memo", []string{"--session", "aaaaaaaa", "--", "-wip check"}, env(nil), time.Now, &out, &out); err != nil {
		t.Fatalf("set: %v", err)
	}
	if err := run(conn, "memo", []string{"--session", "aaaaaaaa"}, env(nil), time.Now, &out, &out); err != nil {
		t.Fatalf("print: %v", err)
	}
	if got, want := out.String(), "-wip check\n"; got != want {
		t.Errorf("printed %q, want %q", got, want)
	}
}

func TestPinCLI_PR(t *testing.T) {
	conn := setup(t)
	e := env(map[string]string{sessionEnv: sid})
	at := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	clock := func() time.Time { return at }
	var out bytes.Buffer
	if err := run(conn, "pin", []string{"--note", "human review", "--pr", "https://github.com/example-org/example-repo/pull/4"}, e, clock, &out, &out); err != nil {
		t.Fatalf("pin --pr: %v", err)
	}
	pinned, note := pinOf(t, conn)
	var pr, cursor sql.NullString
	if err := conn.QueryRow("SELECT pin_pr, pin_cursor FROM sessions WHERE session_id = ?", sid).Scan(&pr, &cursor); err != nil {
		t.Fatal(err)
	}
	if !pinned || note.String != "human review" || pr.String != "example-org/example-repo#4" || cursor.String != "2026-10-26T09:00:00Z" {
		t.Errorf("after pin --pr: pinned=%v note=%v pr=%v cursor=%v", pinned, note, pr, cursor)
	}

	// A plain pin afterwards keeps the watch: it only touches the note.
	if err := run(conn, "pin", []string{"--note", "still waiting"}, e, clock, &out, &out); err != nil {
		t.Fatal(err)
	}
	if err := conn.QueryRow("SELECT pin_pr FROM sessions WHERE session_id = ?", sid).Scan(&pr); err != nil || pr.String != "example-org/example-repo#4" {
		t.Errorf("plain pin dropped the PR watch: %v, %v", pr, err)
	}

	var errOut bytes.Buffer
	if err := run(conn, "pin", []string{"--pr", "not-a-pr"}, e, clock, &out, &errOut); !errors.Is(err, errUsage) {
		t.Errorf("pin --pr not-a-pr = %v, want errUsage", err)
	}
}
