package reconcile

import (
	"path/filepath"
	"reflect"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

func TestToClose(t *testing.T) {
	cases := []struct {
		name    string
		tracked []string
		live    []string
		want    []string
	}{
		{
			name:    "roster lists every tracked session",
			tracked: []string{"a", "b"},
			live:    []string{"b", "a", "c"},
			want:    nil,
		},
		{
			name:    "sessions missing from the roster are closed, in tracked order",
			tracked: []string{"a", "b", "c"},
			live:    []string{"b"},
			want:    []string{"a", "c"},
		},
		{
			// The disappearance this whole package exists for: an empty roster
			// really does mean nothing is running, so everything tracked closes.
			// It is only an UNREADABLE roster that must not reach here -- Sweep
			// keeps that case out by erroring instead of passing an empty slice.
			name:    "an empty roster closes everything tracked",
			tracked: []string{"a", "b"},
			live:    nil,
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

	for _, id := range []string{"ghost", "alive"} {
		if _, err := conn.Exec(
			"INSERT INTO sessions(session_id) VALUES (?)", id,
		); err != nil {
			t.Fatalf("insert session %s: %v", id, err)
		}
		if _, err := conn.Exec(
			"INSERT INTO events(session_id, event_type, state) VALUES (?, 'Stop', 'idle_done')", id,
		); err != nil {
			t.Fatalf("insert event %s: %v", id, err)
		}
	}

	tracked, err := db.LiveSessionIDs(conn)
	if err != nil {
		t.Fatalf("LiveSessionIDs: %v", err)
	}
	closing := ToClose(tracked, []string{"alive"})
	if !reflect.DeepEqual(closing, []string{"ghost"}) {
		t.Fatalf("ToClose = %v, want [ghost]", closing)
	}
	for _, id := range closing {
		if err := db.TerminateSession(conn, id); err != nil {
			t.Fatalf("TerminateSession %s: %v", id, err)
		}
	}

	var remaining []string
	rows, err := conn.Query("SELECT session_id FROM queue")
	if err != nil {
		t.Fatalf("query queue: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			t.Fatalf("scan: %v", err)
		}
		remaining = append(remaining, id)
	}
	if !reflect.DeepEqual(remaining, []string{"alive"}) {
		t.Errorf("queue after sweep = %v, want [alive]", remaining)
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
