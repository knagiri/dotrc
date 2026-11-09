package prref

import (
	"bytes"
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

func rfc(sec int64) string { return time.Unix(sec, 0).UTC().Format(time.RFC3339) }

func TestPickPR(t *testing.T) {
	list := `[{"number":10,"createdAt":"` + rfc(500) + `"},{"number":30,"createdAt":"` + rfc(2500) + `"},{"number":20,"createdAt":"` + rfc(1500) + `"}]`
	if pr, ok, err := pickPR([]byte(list), 1000); err != nil || !ok || pr != 30 {
		t.Errorf("pickPR = %d, %v, %v; want 30", pr, ok, err)
	}
	only := `[{"number":10,"createdAt":"` + rfc(500) + `"}]`
	if pr, ok, err := pickPR([]byte(only), 1000); err != nil || ok {
		t.Errorf("pickPR before since = %d, %v, %v; want not ok", pr, ok, err)
	}
	if _, ok, err := pickPR([]byte(`[]`), 1000); err != nil || ok {
		t.Errorf("pickPR empty = %v, %v; want not ok", ok, err)
	}
	if _, _, err := pickPR([]byte(`not json`), 1000); err == nil {
		t.Error("pickPR on garbage: want an error")
	}
}

func ledger(t *testing.T) *sql.DB {
	t.Helper()
	conn, err := db.Open(filepath.Join(t.TempDir(), "q.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func exec(t *testing.T, conn *sql.DB, q string, args ...any) {
	t.Helper()
	if _, err := conn.Exec(q, args...); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
}

func prOf(t *testing.T, conn *sql.DB, child string) sql.NullInt64 {
	t.Helper()
	var pr sql.NullInt64
	if err := conn.QueryRow("SELECT pr FROM session_links WHERE child_short = ?", child).Scan(&pr); err != nil {
		t.Fatal(err)
	}
	return pr
}

// A delegate re-delegated for review is linked after the PR already exists;
// it still gets that PR, because the bound is the group's oldest link.
func TestPass_RedelegatedChildGetsExistingPR(t *testing.T) {
	conn := ledger(t)
	exec(t, conn, "INSERT INTO sessions(session_id, cwd) VALUES ('P1', '/work/p1')")
	exec(t, conn, `INSERT INTO session_links(child_short, parent_session_id, repo, branch, created_at, pr)
		VALUES ('c1c1c1c1', 'P1', 'example-org/example-repo', 'feat/foo', 1000, 42),
		       ('c2c2c2c2', 'P1', 'example-org/example-repo', 'feat/foo', 3000, NULL)`)
	var gotArgv []string
	var gotDir string
	run := func(argv []string, dir string) ([]byte, error) {
		gotArgv, gotDir = argv, dir
		return []byte(`[{"number":42,"createdAt":"` + rfc(2000) + `"}]`), nil
	}
	var out bytes.Buffer
	Pass(conn, run, &out)
	if pr := prOf(t, conn, "c2c2c2c2"); pr.Int64 != 42 {
		t.Fatalf("pr = %+v, want 42; output:\n%s", pr, &out)
	}
	want := "gh pr list --repo example-org/example-repo --head feat/foo --state all --json number,createdAt"
	if strings.Join(gotArgv, " ") != want || gotDir != "/work/p1" {
		t.Errorf("ran %q in %q, want %q in /work/p1", gotArgv, gotDir, want)
	}
	if !strings.Contains(out.String(), "pr-refs: resolved 1, pending 0") {
		t.Errorf("summary missing:\n%s", &out)
	}
}

// A PR made for an earlier use of the branch name, before the delegation, is
// not this delegation's.
func TestPass_IgnoresPRBeforeLink(t *testing.T) {
	conn := ledger(t)
	exec(t, conn, "INSERT INTO sessions(session_id, cwd) VALUES ('P1', '/work/p1')")
	exec(t, conn, `INSERT INTO session_links(child_short, parent_session_id, repo, branch, created_at)
		VALUES ('c1c1c1c1', 'P1', 'example-org/example-repo', 'feat/foo', 3000)`)
	run := func([]string, string) ([]byte, error) {
		return []byte(`[{"number":7,"createdAt":"` + rfc(2000) + `"}]`), nil
	}
	var out bytes.Buffer
	Pass(conn, run, &out)
	if pr := prOf(t, conn, "c1c1c1c1"); pr.Valid {
		t.Fatalf("pr = %+v, want NULL", pr)
	}
	if !strings.Contains(out.String(), "pr-refs: resolved 0, pending 1") {
		t.Errorf("summary missing:\n%s", &out)
	}
}

// One group's gh failure costs that group only.
func TestPass_GhFailureSkipsOnlyThatGroup(t *testing.T) {
	conn := ledger(t)
	exec(t, conn, "INSERT INTO sessions(session_id, cwd) VALUES ('P1', '/work/p1')")
	exec(t, conn, `INSERT INTO session_links(child_short, parent_session_id, repo, branch, created_at)
		VALUES ('c1c1c1c1', 'P1', 'example-org/example-repo', 'feat/bar', 1000),
		       ('c2c2c2c2', 'P1', 'example-org/example-repo', 'feat/foo', 1000)`)
	run := func(argv []string, _ string) ([]byte, error) {
		if strings.Contains(strings.Join(argv, " "), "--head feat/bar ") {
			return nil, errors.New("no token")
		}
		return []byte(`[{"number":5,"createdAt":"` + rfc(2000) + `"}]`), nil
	}
	var out bytes.Buffer
	Pass(conn, run, &out)
	if pr := prOf(t, conn, "c1c1c1c1"); pr.Valid {
		t.Errorf("failed group written: pr = %+v", pr)
	}
	if pr := prOf(t, conn, "c2c2c2c2"); pr.Int64 != 5 {
		t.Errorf("other group: pr = %+v, want 5", pr)
	}
	for _, want := range []string{"pr-refs: example-org/example-repo feat/bar: no token", "pr-refs: resolved 1, pending 1"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("output lacks %q:\n%s", want, &out)
		}
	}
}

// Two delegators on the same repo and branch cost one gh call.
func TestPass_OneCallPerRepoBranch(t *testing.T) {
	conn := ledger(t)
	exec(t, conn, "INSERT INTO sessions(session_id, cwd) VALUES ('P1', '/work/p1'), ('P2', '/work/p2')")
	exec(t, conn, `INSERT INTO session_links(child_short, parent_session_id, repo, branch, created_at)
		VALUES ('c1c1c1c1', 'P1', 'example-org/example-repo', 'feat/foo', 1000),
		       ('c2c2c2c2', 'P2', 'example-org/example-repo', 'feat/foo', 1000)`)
	calls := 0
	run := func([]string, string) ([]byte, error) {
		calls++
		return []byte(`[{"number":5,"createdAt":"` + rfc(2000) + `"}]`), nil
	}
	Pass(conn, run, &bytes.Buffer{})
	if calls != 1 {
		t.Errorf("gh calls = %d, want 1", calls)
	}
	if prOf(t, conn, "c1c1c1c1").Int64 != 5 || prOf(t, conn, "c2c2c2c2").Int64 != 5 {
		t.Error("both groups should be resolved")
	}
}
