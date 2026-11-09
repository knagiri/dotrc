package db

import (
	"path/filepath"
	"testing"
)

func refsLedger(t *testing.T) *refsT {
	t.Helper()
	conn, err := Open(filepath.Join(t.TempDir(), "refs.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return &refsT{t: t, exec: func(q string, args ...any) {
		t.Helper()
		if _, err := conn.Exec(q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}, refs: func() map[string]string {
		t.Helper()
		m, err := TreeRefs(conn)
		if err != nil {
			t.Fatalf("TreeRefs: %v", err)
		}
		return m
	}}
}

type refsT struct {
	t    *testing.T
	exec func(string, ...any)
	refs func() map[string]string
}

const (
	p1 = "p1p1p1p1-0000-0000-0000-000000000000"
	c1 = "c1c1c1c1-0000-0000-0000-000000000000"
	c2 = "c2c2c2c2-0000-0000-0000-000000000000"
	c3 = "c3c3c3c3-0000-0000-0000-000000000000"
)

// Every member of a tree -- the root, a done child, a grandchild -- carries the
// whole tree's refs, oldest link first; a session outside any tree carries none.
func TestTreeRefs_AllMembersShareRootValue(t *testing.T) {
	r := refsLedger(t)
	r.exec(`INSERT INTO session_links(child_short, parent_session_id, repo, branch, pr, created_at) VALUES
		('c1c1c1c1', ?, 'example-org/example-repo', 'feat/foo', 42, 100),
		('c2c2c2c2', ?, 'example-org/example-repo', 'feat/bar', NULL, 200),
		('c3c3c3c3', ?, 'example-org/example-repo', 'feat/baz', NULL, 300)`, p1, p1, c2)
	r.exec(`INSERT INTO session_links(child_short, parent_session_id, created_at) VALUES ('d2d2d2d2', 'd1d1d1d1-x', 50)`)
	got := r.refs()
	const want = "#42 feat/foo  feat/bar  feat/baz"
	for _, k := range []string{"p1p1p1p1", "c1c1c1c1", "c2c2c2c2", "c3c3c3c3"} {
		if got[k] != want {
			t.Errorf("%s = %q, want %q", k, got[k], want)
		}
	}
	// A tree whose links carry no branch has nothing to show.
	for _, k := range []string{"d1d1d1d1", "d2d2d2d2"} {
		if v, ok := got[k]; ok {
			t.Errorf("%s = %q, want no entry", k, v)
		}
	}
}

// A delegate re-delegated on the same branch shows once, with its PR.
func TestTreeRefs_DedupKeepsPR(t *testing.T) {
	r := refsLedger(t)
	r.exec(`INSERT INTO session_links(child_short, parent_session_id, repo, branch, pr, created_at) VALUES
		('c1c1c1c1', ?, 'example-org/example-repo', 'feat/foo', NULL, 100),
		('c2c2c2c2', ?, 'example-org/example-repo', 'feat/foo', 42, 200),
		('c3c3c3c3', ?, 'example-org/example-repo', 'feat/bar', NULL, 300)`, p1, p1, p1)
	if got := r.refs()["p1p1p1p1"]; got != "#42 feat/foo  feat/bar" {
		t.Errorf("got %q", got)
	}
}

// A broken ledger whose links loop must not hang the picker.
func TestTreeRefs_CycleTerminates(t *testing.T) {
	r := refsLedger(t)
	r.exec(`INSERT INTO session_links(child_short, parent_session_id, branch, created_at) VALUES
		('aaaaaaaa', 'bbbbbbbb-x', 'feat/foo', 100),
		('bbbbbbbb', 'aaaaaaaa-x', 'feat/bar', 200)`)
	got := r.refs()
	if got["aaaaaaaa"] != got["bbbbbbbb"] || got["aaaaaaaa"] == "" {
		t.Errorf("cycle members disagree or are empty: %q", got)
	}
}
