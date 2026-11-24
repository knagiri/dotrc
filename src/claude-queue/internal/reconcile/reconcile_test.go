package reconcile

import (
	"database/sql"
	"errors"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

func tracked(ids ...string) []db.LiveSession {
	out := make([]db.LiveSession, 0, len(ids))
	for _, id := range ids {
		out = append(out, db.LiveSession{SessionID: id})
	}
	return out
}

func TestToClose(t *testing.T) {
	cases := []struct {
		name    string
		tracked []db.LiveSession
		live    []string
		want    []string
	}{
		{
			name:    "roster lists every tracked session",
			tracked: tracked("a", "b"),
			live:    []string{"b", "a", "c"},
			want:    nil,
		},
		{
			name:    "sessions missing from the roster are closed, in tracked order",
			tracked: tracked("a", "b", "c"),
			live:    []string{"b"},
			want:    []string{"a", "c"},
		},
		{
			// The disappearance this whole package exists for: an empty roster
			// really does mean nothing is running, so everything tracked
			// closes. It is only an UNREADABLE roster that must not reach
			// here -- Sweep returns before calling ToClose in that case.
			name:    "an empty roster closes everything tracked",
			tracked: tracked("a", "b"),
			live:    []string{},
			want:    []string{"a", "b"},
		},
		{
			name:    "nothing tracked is a no-op",
			tracked: nil,
			live:    []string{"a"},
			want:    nil,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ToClose(tc.tracked, tc.live)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("ToClose(%v, %v) = %v, want %v", tc.tracked, tc.live, got, tc.want)
			}
		})
	}
}

// The ledger side of the sweep: rows named by ToClose must actually leave the
// queue view, and rows still on the roster must stay.
func TestTerminateSessionRemovesRowFromQueue(t *testing.T) {
	conn, err := db.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	for _, id := range []string{"ghost", "alive", "alive-2"} {
		if _, err := conn.Exec("INSERT INTO sessions(session_id) VALUES (?)", id); err != nil {
			t.Fatalf("insert session %s: %v", id, err)
		}
		if _, err := conn.Exec(
			"INSERT INTO events(session_id, event_type, state) VALUES (?, 'Stop', 'idle_done')", id,
		); err != nil {
			t.Fatalf("insert event %s: %v", id, err)
		}
	}

	live, err := db.LiveSessions(conn)
	if err != nil {
		t.Fatalf("LiveSessions: %v", err)
	}
	closing := ToClose(live, []string{"alive", "alive-2"})
	if !reflect.DeepEqual(closing, []string{"ghost"}) {
		t.Fatalf("ToClose = %v, want [ghost]", closing)
	}
	for _, id := range closing {
		if err := db.TerminateSession(conn, id); err != nil {
			t.Fatalf("TerminateSession %s: %v", id, err)
		}
	}

	var remaining []string
	// The ghost stays in the view as gone -- its work is still open -- so only
	// the running rows are compared.
	qrows, err := conn.Query("SELECT session_id FROM queue WHERE effective_state != 'gone' ORDER BY session_id")
	if err != nil {
		t.Fatalf("query queue: %v", err)
	}
	defer qrows.Close()
	for qrows.Next() {
		var id string
		if err := qrows.Scan(&id); err != nil {
			t.Fatalf("scan: %v", err)
		}
		remaining = append(remaining, id)
	}
	if !reflect.DeepEqual(remaining, []string{"alive", "alive-2"}) {
		t.Errorf("queue after sweep = %v, want [alive alive-2]", remaining)
	}
}

// The projection Sweep feeds to ToClose. An agent without a session id has to be
// dropped rather than passed through as "": ToClose matches on equality, so a ""
// in the live set would spare any tracked row that also lost its id.
func TestSessionIDs(t *testing.T) {
	got := sessionIDs([]roster.Agent{
		{SessionID: "a", PID: 1},
		{SessionID: "", PID: 2},
		{SessionID: "b", PID: 3},
	})
	if !reflect.DeepEqual(got, []string{"a", "b"}) {
		t.Errorf("sessionIDs = %v, want [a b]", got)
	}
	if got := sessionIDs(nil); len(got) != 0 {
		t.Errorf("sessionIDs(nil) = %v, want empty", got)
	}
}

// sweepFixture is a ledger with one background session of each kind the stop
// pass must tell apart.
func sweepFixture(t *testing.T) *sql.DB {
	t.Helper()
	conn, err := db.Open(filepath.Join(t.TempDir(), "s.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	for _, q := range []string{
		"INSERT INTO sessions(session_id, kind) VALUES " +
			"('done-run-0000', 'background'), " +
			"('open-run-0000', 'background'), " +
			"('done-ia-00000', 'interactive')",
		"UPDATE sessions SET done_at = unixepoch() WHERE session_id IN ('done-run-0000', 'done-ia-00000')",
	} {
		if _, err := conn.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	return conn
}

func TestSweep_StopsDoneButRunningBackground(t *testing.T) {
	conn := sweepFixture(t)
	var stopped []string
	res, err := sweep(conn,
		func() ([]string, error) {
			return []string{"done-run-0000", "open-run-0000", "done-ia-00000"}, nil
		},
		func(id string) error { stopped = append(stopped, id); return nil },
	)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"done-run-0000"}; !reflect.DeepEqual(stopped, want) {
		t.Errorf("stopped = %v, want %v", stopped, want)
	}
	if res.Stopped != 1 || res.Closed != 0 {
		t.Errorf("result = %+v, want Stopped 1, Closed 0", res)
	}
}

// Open work is never stopped, and neither is a done session the roster cannot
// vouch for: an unreadable roster is no evidence anything is running.
func TestSweep_DoesNotStopOpenSession(t *testing.T) {
	conn := sweepFixture(t)
	if _, err := conn.Exec("UPDATE sessions SET done_at = NULL WHERE session_id = 'done-run-0000'"); err != nil {
		t.Fatal(err)
	}
	called := false
	stop := func(string) error { called = true; return nil }
	if _, err := sweep(conn, func() ([]string, error) {
		return []string{"done-run-0000", "open-run-0000", "done-ia-00000"}, nil
	}, stop); err != nil {
		t.Fatal(err)
	}
	if called {
		t.Error("an open session was stopped")
	}

	conn = sweepFixture(t)
	res, err := sweep(conn, func() ([]string, error) { return nil, errors.New("roster down") }, stop)
	if err == nil {
		t.Error("a sweep on an unreadable roster did not report an error")
	}
	if res.Closed != 0 {
		t.Errorf("a sweep on an unreadable roster closed %d row(s)", res.Closed)
	}
	if live, err := db.LiveSessions(conn); err != nil || len(live) != 3 {
		t.Errorf("rows left open after an unreadable roster = %v (%v), want all 3", live, err)
	}
	if called {
		t.Error("a session was stopped on an unreadable roster")
	}
}

// A failed stop is reported, not fatal: the session stays done and the next
// sweep tries again.
func TestSweep_StopFailureIsReported(t *testing.T) {
	conn := sweepFixture(t)
	res, err := sweep(conn,
		func() ([]string, error) {
			return []string{"done-run-0000", "open-run-0000", "done-ia-00000"}, nil
		},
		func(string) error { return errors.New("boom") },
	)
	if err != nil {
		t.Fatal(err)
	}
	if res.Stopped != 0 || len(res.StopErrors) != 1 {
		t.Errorf("result = %+v, want one stop error", res)
	}
}
