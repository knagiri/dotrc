package reconcile

import (
	"path/filepath"
	"reflect"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// The two config dirs every case below is written against: the default one and
// a second one, standing in for the personal dir the ledger will start carrying
// rows from.
const (
	dirWork     = "/home/x/.claude"
	dirPersonal = "/home/x/.claude-personal"
)

func tracked(pairs ...[2]string) []db.LiveSession {
	out := make([]db.LiveSession, 0, len(pairs))
	for _, p := range pairs {
		out = append(out, db.LiveSession{SessionID: p[0], ConfigDir: p[1]})
	}
	return out
}

func TestToClose(t *testing.T) {
	cases := []struct {
		name    string
		tracked []db.LiveSession
		live    map[string][]string
		want    []string
	}{
		{
			name:    "roster lists every tracked session",
			tracked: tracked([2]string{"a", dirWork}, [2]string{"b", dirWork}),
			live:    map[string][]string{dirWork: {"b", "a", "c"}},
			want:    nil,
		},
		{
			name:    "sessions missing from the roster are closed, in tracked order",
			tracked: tracked([2]string{"a", dirWork}, [2]string{"b", dirWork}, [2]string{"c", dirWork}),
			live:    map[string][]string{dirWork: {"b"}},
			want:    []string{"a", "c"},
		},
		{
			// The disappearance this whole package exists for: an empty roster
			// really does mean nothing is running, so everything tracked under
			// that dir closes. It is only an UNREADABLE roster that must not
			// reach here -- Sweep keeps that case out by omitting the dir from
			// the map instead of mapping it to an empty slice.
			name:    "an empty roster closes everything tracked under that dir",
			tracked: tracked([2]string{"a", dirWork}, [2]string{"b", dirWork}),
			live:    map[string][]string{dirWork: {}},
			want:    []string{"a", "b"},
		},
		{
			name:    "nothing tracked is a no-op",
			tracked: nil,
			live:    map[string][]string{dirWork: {"a"}},
			want:    nil,
		},
		{
			// THE regression this change exists for. Both dirs are readable and
			// each lists its own session. Matching a row against the union of
			// every roster, or against one dir's roster alone, closes the other
			// dir's live row -- which is what the picker did on every open
			// before the rows carried a config dir.
			name:    "a session live in its own dir is not closed by another dir's roster",
			tracked: tracked([2]string{"work-1", dirWork}, [2]string{"personal-1", dirPersonal}),
			live: map[string][]string{
				dirWork:     {"work-1"},
				dirPersonal: {"personal-1"},
			},
			want: nil,
		},
		{
			// The other half of the same fixture: dir scoping must not make the
			// sweep useless. A row whose OWN dir's roster does not list it still
			// closes, even though the other dir's roster is non-empty.
			name:    "a session missing from its own dir still closes",
			tracked: tracked([2]string{"work-1", dirWork}, [2]string{"personal-1", dirPersonal}),
			live: map[string][]string{
				dirWork:     {"work-1"},
				dirPersonal: {},
			},
			want: []string{"personal-1"},
		},
		{
			// An unreadable dir is absent from the map, which must be read as
			// "no evidence", not as "an empty roster". The readable dir is still
			// swept, so one broken daemon does not stall the whole pass.
			name:    "rows under a dir whose roster could not be read are left open",
			tracked: tracked([2]string{"work-gone", dirWork}, [2]string{"personal-1", dirPersonal}),
			live:    map[string][]string{dirWork: {}},
			want:    []string{"work-gone"},
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
// queue view, and rows still on the roster must stay -- including one whose
// roster is a different config dir's.
func TestTerminateSessionRemovesRowFromQueue(t *testing.T) {
	conn, err := db.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	rows := []struct{ id, dir string }{
		{"ghost", dirWork},
		{"alive", dirWork},
		{"personal-alive", dirPersonal},
	}
	for _, r := range rows {
		if _, err := conn.Exec(
			"INSERT INTO sessions(session_id, config_dir) VALUES (?, ?)", r.id, r.dir,
		); err != nil {
			t.Fatalf("insert session %s: %v", r.id, err)
		}
		if _, err := conn.Exec(
			"INSERT INTO events(session_id, event_type, state) VALUES (?, 'Stop', 'idle_done')", r.id,
		); err != nil {
			t.Fatalf("insert event %s: %v", r.id, err)
		}
	}

	live, err := db.LiveSessions(conn)
	if err != nil {
		t.Fatalf("LiveSessions: %v", err)
	}
	closing := ToClose(live, map[string][]string{
		dirWork:     {"alive"},
		dirPersonal: {"personal-alive"},
	})
	if !reflect.DeepEqual(closing, []string{"ghost"}) {
		t.Fatalf("ToClose = %v, want [ghost]", closing)
	}
	for _, id := range closing {
		if err := db.TerminateSession(conn, id); err != nil {
			t.Fatalf("TerminateSession %s: %v", id, err)
		}
	}

	var remaining []string
	qrows, err := conn.Query("SELECT session_id FROM queue ORDER BY session_id")
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
	if !reflect.DeepEqual(remaining, []string{"alive", "personal-alive"}) {
		t.Errorf("queue after sweep = %v, want [alive personal-alive]", remaining)
	}
}

// dirsOf names the rosters a sweep has to read: one entry per dir that actually
// carries a live row, in first-seen order so the reads (and any failures
// reported from them) come out stably.
func TestDirsOf(t *testing.T) {
	got := dirsOf(tracked(
		[2]string{"a", dirWork},
		[2]string{"b", dirPersonal},
		[2]string{"c", dirWork},
	))
	if !reflect.DeepEqual(got, []string{dirWork, dirPersonal}) {
		t.Errorf("dirsOf = %v, want [%s %s]", got, dirWork, dirPersonal)
	}
	if got := dirsOf(nil); len(got) != 0 {
		t.Errorf("dirsOf(nil) = %v, want empty", got)
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
