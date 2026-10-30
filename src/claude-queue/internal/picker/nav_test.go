package picker

import (
	"database/sql"
	"path/filepath"
	"slices"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// navFixture is a ledger of sessions A..E, each running in pane %<n> under
// pid 100+n, with history A B C D E and the cursor on E. A session listed in
// ended has no process left: it is gone from the roster and its row is
// terminated.
type navFixture struct {
	conn     *sql.DB
	switched []string
	agents   []roster.Agent
	mux      *fakeMux
}

var navSessions = []string{"A", "B", "C", "D", "E"}

func newNavFixture(t *testing.T, ended ...string) *navFixture {
	t.Helper()
	conn, err := db.Open(filepath.Join(t.TempDir(), "nav.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	f := &navFixture{conn: conn, mux: &fakeMux{find: map[int]string{}}}
	for i, id := range navSessions {
		pane, pid := "%"+string(rune('0'+i)), 100+i
		if _, err := conn.Exec("INSERT INTO sessions(session_id, tmux_pane) VALUES (?, ?)", id, pane); err != nil {
			t.Fatal(err)
		}
		if slices.Contains(ended, id) {
			if _, err := conn.Exec("UPDATE sessions SET terminated_at = 1 WHERE session_id = ?", id); err != nil {
				t.Fatal(err)
			}
			continue
		}
		f.agents = append(f.agents, roster.Agent{SessionID: id, PID: pid, Kind: roster.KindInteractive})
		f.mux.find[pid] = pane
	}
	for _, id := range navSessions {
		if err := db.PushNav(conn, "", id); err != nil {
			t.Fatal(err)
		}
	}
	return f
}

func paneOf(id string) string {
	return "%" + string(rune('0'+slices.Index(navSessions, id)))
}

// walk runs walkHistory from the pane of the session at, and reports the pane
// it switched to ("" for none) and the session the cursor ends on.
func (f *navFixture) walk(t *testing.T, step int, at string) (string, string) {
	t.Helper()
	f.switched = nil
	moved, err := walkHistory(f.conn, step, paneOf(at), navDeps{
		Mux:    f.mux,
		List:   func(string) ([]roster.Agent, error) { return f.agents, nil },
		Switch: func(p string) error { f.switched = append(f.switched, p); return nil },
	})
	if err != nil {
		t.Fatalf("walkHistory: %v", err)
	}
	if moved != (len(f.switched) == 1) {
		t.Fatalf("moved = %v but switched %v", moved, f.switched)
	}
	hist, idx, _ := db.NavHistory(f.conn)
	got := ""
	if moved {
		got = f.switched[0]
	}
	return got, hist[idx].SessionID
}

func TestWalkHistory(t *testing.T) {
	cases := []struct {
		name     string
		ended    []string
		setup    func(t *testing.T, f *navFixture) // walks before the one under test
		step     int
		at       string // the session the client is in
		wantPane string
		wantAt   string
	}{
		{name: "back from the cursor goes to the entry before it", step: -1, at: "E", wantPane: paneOf("D"), wantAt: "D"},
		{name: "back after a hand move returns to the cursor entry itself", step: -1, at: "B", wantPane: paneOf("E"), wantAt: "E"},
		{name: "back passes over sessions that ended", ended: []string{"D", "C"}, step: -1, at: "E", wantPane: paneOf("B"), wantAt: "B"},
		{name: "back stops at the oldest entry", ended: []string{"A"}, step: -1, at: "B",
			setup: func(t *testing.T, f *navFixture) {
				for _, at := range []string{"E", "D", "C"} {
					f.walk(t, -1, at)
				}
			},
			wantPane: "", wantAt: "B"},
		{name: "forward goes to the entry after the cursor", step: 1, at: "C",
			setup:    func(t *testing.T, f *navFixture) { f.walk(t, -1, "E"); f.walk(t, -1, "D") },
			wantPane: paneOf("D"), wantAt: "D"},
		{name: "forward passes over sessions that ended", ended: []string{"D"}, step: 1, at: "C",
			setup:    func(t *testing.T, f *navFixture) { f.walk(t, -1, "E"); f.walk(t, -1, "D") },
			wantPane: paneOf("E"), wantAt: "E"},
		{name: "forward stops at the newest entry", step: 1, at: "E", wantPane: "", wantAt: "E"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newNavFixture(t, c.ended...)
			if c.setup != nil {
				c.setup(t, f)
			}
			pane, at := f.walk(t, c.step, c.at)
			if pane != c.wantPane || at != c.wantAt {
				t.Errorf("switched to %q, cursor on %q; want %q, %q", pane, at, c.wantPane, c.wantAt)
			}
		})
	}
}

// A walk moves the cursor only: the history it walks keeps every entry.
func TestWalkHistoryRecordsNothing(t *testing.T) {
	f := newNavFixture(t)
	f.walk(t, -1, "E")
	f.walk(t, -1, "D")
	f.walk(t, 1, "C")
	hist, _, _ := db.NavHistory(f.conn)
	var ids []string
	for _, e := range hist {
		ids = append(ids, e.SessionID)
	}
	if !slices.Equal(ids, navSessions) {
		t.Errorf("history = %v, want %v untouched", ids, navSessions)
	}
}

// A pick records the session it was opened over as well, resolved from the
// origin pane, so the very first jump can be walked back.
func TestRecordJumpPushesOrigin(t *testing.T) {
	f := newNavFixture(t)
	if _, err := f.conn.Exec("DELETE FROM nav_history"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.conn.Exec("DELETE FROM nav_cursor"); err != nil {
		t.Fatal(err)
	}
	recordJump(f.conn, paneOf("B"), "D")
	pane, at := f.walk(t, -1, "D")
	if pane != paneOf("B") || at != "B" {
		t.Errorf("back after the first pick switched to %q, cursor on %q; want %q, B", pane, at, paneOf("B"))
	}
}
