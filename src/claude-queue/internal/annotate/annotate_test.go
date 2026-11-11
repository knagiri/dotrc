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

// pin has no --pr: watching a PR is follow's, and leaves the pin alone.
func TestPinCLI_NoPRFlag(t *testing.T) {
	conn := setup(t)
	e := env(map[string]string{sessionEnv: sid})
	var out bytes.Buffer
	if err := run(conn, "pin", []string{"--note", "n", "--pr", "example-org/example-repo#4"}, e, time.Now, &out, &out); !errors.Is(err, errUsage) {
		t.Fatalf("pin --pr = %v, want errUsage", err)
	}
	if pinned, _ := pinOf(t, conn); pinned {
		t.Error("a rejected pin --pr pinned the session")
	}
	if n := watchCount(t, conn); n != 0 {
		t.Errorf("a rejected pin --pr left %d watches", n)
	}
}

// A pin put on or taken off leaves a watch as it was.
func TestPinCLI_LeavesWatch(t *testing.T) {
	conn := setup(t)
	e := env(map[string]string{sessionEnv: sid})
	var out bytes.Buffer
	if err := run(conn, "follow", []string{"--note", "human review", "--pr", "example-org/example-repo#4"}, e, time.Now, &out, &out); err != nil {
		t.Fatal(err)
	}
	w := watchOf(t, conn, "example-org/example-repo#4")
	for _, c := range []struct {
		cmd  string
		args []string
	}{{"pin", []string{"--note", "still waiting"}}, {"unpin", nil}} {
		if err := run(conn, c.cmd, c.args, e, time.Now, &out, &out); err != nil {
			t.Fatal(err)
		}
		if got := watchOf(t, conn, "example-org/example-repo#4"); got != w {
			t.Errorf("%s changed the watch: %+v, was %+v", c.cmd, got, w)
		}
	}
}

type watch struct {
	cursor, note, halted sql.NullString
	failures             sql.NullInt64
}

// watchOf reads the session's watch of pr and fails when there is none.
func watchOf(t *testing.T, conn *sql.DB, pr string) watch {
	t.Helper()
	var w watch
	if err := conn.QueryRow("SELECT cursor, note, halted_upto, failures FROM pr_watches WHERE session_id = ? AND pr = ?", sid, pr).
		Scan(&w.cursor, &w.note, &w.halted, &w.failures); err != nil {
		t.Fatalf("watch of %s: %v", pr, err)
	}
	return w
}

func watchCount(t *testing.T, conn *sql.DB) int {
	t.Helper()
	var n int
	if err := conn.QueryRow("SELECT COUNT(*) FROM pr_watches").Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// follow sets a watch and does not pin; --session falls back to the env, and a
// URL is stored as owner/repo#N.
func TestFollowCLI(t *testing.T) {
	conn := setup(t)
	e := env(map[string]string{sessionEnv: sid})
	at := time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)
	clock := func() time.Time { return at }
	var out bytes.Buffer
	if err := run(conn, "follow", []string{"--note", "human review", "--pr", "https://github.com/example-org/example-repo/pull/4"}, e, clock, &out, &out); err != nil {
		t.Fatalf("follow: %v", err)
	}
	if pinned, note := pinOf(t, conn); pinned || note.Valid {
		t.Errorf("follow touched the pin: pinned=%v note=%v", pinned, note)
	}
	w := watchOf(t, conn, "example-org/example-repo#4")
	if w.cursor.String != "2026-10-26T09:00:00Z" || w.note.String != "human review" {
		t.Errorf("watch = %+v", w)
	}

	// Following the same PR again starts it over, a stop included; without
	// --note the note stays.
	if _, err := conn.Exec("UPDATE pr_watches SET failures = 3, halted_upto = 'x'"); err != nil {
		t.Fatal(err)
	}
	at = at.Add(time.Hour)
	if err := run(conn, "follow", []string{"--pr", "example-org/example-repo#4"}, e, clock, &out, &out); err != nil {
		t.Fatalf("follow again: %v", err)
	}
	w = watchOf(t, conn, "example-org/example-repo#4")
	if w.cursor.String != "2026-10-26T10:00:00Z" || w.note.String != "human review" || w.failures.Valid || w.halted.Valid {
		t.Errorf("after following again: %+v", w)
	}

	// A second PR does not replace the first.
	if err := run(conn, "follow", []string{"--session", "aaaaaaaa", "--pr", "example-org/example-repo#5"}, env(nil), clock, &out, &out); err != nil {
		t.Fatalf("follow a second PR: %v", err)
	}
	if n := watchCount(t, conn); n != 2 {
		t.Errorf("watches = %d, want 2", n)
	}
}

func TestFollowCLI_BadUsage(t *testing.T) {
	conn := setup(t)
	e := env(map[string]string{sessionEnv: sid})
	var out bytes.Buffer
	for _, args := range [][]string{nil, {"--note", "x"}, {"--pr", "not-a-pr"}, {"--pr", "a/b#1", "stray"}} {
		if err := run(conn, "follow", args, e, time.Now, &out, &out); !errors.Is(err, errUsage) {
			t.Errorf("follow %q = %v, want errUsage", args, err)
		}
	}
	if err := run(conn, "follow", []string{"--pr", "a/b#1"}, env(nil), time.Now, &out, &out); !errors.Is(err, errUsage) {
		t.Errorf("follow without a session = %v, want errUsage", err)
	}
	if n := watchCount(t, conn); n != 0 {
		t.Errorf("a bad follow left %d watches", n)
	}
}

func TestFollowCLI_DoneSessionFails(t *testing.T) {
	conn := setup(t)
	if _, err := conn.Exec("UPDATE sessions SET done_at = 1"); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := run(conn, "follow", []string{"--pr", "a/b#1"}, env(map[string]string{sessionEnv: sid}), time.Now, &out, &out); !errors.Is(err, db.ErrDone) {
		t.Errorf("follow on done = %v, want ErrDone", err)
	}
}

// unfollow --pr removes that watch, unfollow alone every watch of the session;
// neither touches the pin, and finding nothing is said but is not a failure.
func TestUnfollowCLI(t *testing.T) {
	conn := setup(t)
	e := env(map[string]string{sessionEnv: sid})
	var out, errOut bytes.Buffer
	for _, pr := range []string{"a/b#1", "a/b#2", "a/b#3"} {
		if err := run(conn, "follow", []string{"--pr", pr}, e, time.Now, &out, &out); err != nil {
			t.Fatal(err)
		}
	}
	if err := run(conn, "pin", []string{"--note", "n"}, e, time.Now, &out, &out); err != nil {
		t.Fatal(err)
	}
	if err := run(conn, "unfollow", []string{"--pr", "https://github.com/a/b/pull/1"}, e, time.Now, &out, &errOut); err != nil {
		t.Fatalf("unfollow --pr: %v", err)
	}
	if n := watchCount(t, conn); n != 2 || errOut.Len() != 0 {
		t.Errorf("after unfollow --pr: %d watches, stderr %q", n, errOut.String())
	}
	if err := run(conn, "unfollow", []string{"--pr", "a/b#1"}, e, time.Now, &out, &errOut); err != nil {
		t.Fatalf("unfollow of a PR not followed: %v", err)
	}
	if n := watchCount(t, conn); n != 2 || errOut.String() != "unfollow: nothing to remove\n" {
		t.Errorf("unfollow of a PR not followed: %d watches, stderr %q", n, errOut.String())
	}
	errOut.Reset()
	if err := run(conn, "unfollow", nil, e, time.Now, &out, &errOut); err != nil {
		t.Fatalf("unfollow: %v", err)
	}
	if n := watchCount(t, conn); n != 0 || errOut.Len() != 0 {
		t.Errorf("after unfollow: %d watches, stderr %q", n, errOut.String())
	}
	if pinned, note := pinOf(t, conn); !pinned || note.String != "n" {
		t.Errorf("unfollow touched the pin: pinned=%v note=%v", pinned, note)
	}
	if err := run(conn, "unfollow", []string{"stray"}, e, time.Now, &out, &out); !errors.Is(err, errUsage) {
		t.Errorf("unfollow stray = %v, want errUsage", err)
	}
}

// A done session keeps its watches (Reopen brings them back), so unfollow is
// refused for it like every other write, with or without --pr.
func TestUnfollowCLI_DoneSessionFails(t *testing.T) {
	for name, args := range map[string][]string{
		"with --pr":    {"--pr", "example-org/example-repo#1"},
		"without --pr": nil,
	} {
		t.Run(name, func(t *testing.T) {
			conn := setup(t)
			e := env(map[string]string{sessionEnv: sid})
			var out bytes.Buffer
			if err := run(conn, "follow", []string{"--pr", "example-org/example-repo#1"}, e, time.Now, &out, &out); err != nil {
				t.Fatal(err)
			}
			if _, err := conn.Exec("UPDATE sessions SET done_at = 1"); err != nil {
				t.Fatal(err)
			}
			if err := run(conn, "unfollow", args, e, time.Now, &out, &out); !errors.Is(err, db.ErrDone) {
				t.Errorf("unfollow on done = %v, want ErrDone", err)
			}
			if n := watchCount(t, conn); n != 1 {
				t.Errorf("unfollow on done left %d watches, want 1", n)
			}
		})
	}
}
