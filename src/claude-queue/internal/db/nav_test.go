package db

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"slices"
	"testing"
)

func openNavDB(t *testing.T) *sql.DB {
	t.Helper()
	conn, err := Open(filepath.Join(t.TempDir(), "nav.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

// navState is the history as session ids, and the cursor's session.
func navState(t *testing.T, conn *sql.DB) ([]string, string) {
	t.Helper()
	hist, idx, err := NavHistory(conn)
	if err != nil {
		t.Fatalf("NavHistory: %v", err)
	}
	var ids []string
	for _, e := range hist {
		ids = append(ids, e.SessionID)
	}
	if idx < 0 {
		return ids, ""
	}
	return ids, hist[idx].SessionID
}

func mustPush(t *testing.T, conn *sql.DB, origin, target string) {
	t.Helper()
	if err := PushNav(conn, origin, target); err != nil {
		t.Fatalf("PushNav(%q, %q): %v", origin, target, err)
	}
}

func TestPushNav(t *testing.T) {
	cases := []struct {
		name       string
		pushes     [][2]string // origin, target
		back       int         // cursor steps back before the last push
		lastOrigin string
		lastTarget string
		want       []string
		wantAt     string
	}{
		{
			name:       "first jump pushes its origin so back has somewhere to go",
			lastOrigin: "A", lastTarget: "B",
			want: []string{"A", "B"}, wantAt: "B",
		},
		{
			name:       "an unknown origin is not pushed",
			lastOrigin: "", lastTarget: "B",
			want: []string{"B"}, wantAt: "B",
		},
		{
			name:       "origin already at the cursor is not pushed again",
			pushes:     [][2]string{{"A", "B"}},
			lastOrigin: "B", lastTarget: "C",
			want: []string{"A", "B", "C"}, wantAt: "C",
		},
		{
			name:       "a jump to the cursor's own session pushes nothing",
			pushes:     [][2]string{{"A", "B"}},
			lastOrigin: "B", lastTarget: "B",
			want: []string{"A", "B"}, wantAt: "B",
		},
		{
			name:       "a hand-moved origin is pushed before the target",
			pushes:     [][2]string{{"A", "B"}},
			lastOrigin: "X", lastTarget: "C",
			want: []string{"A", "B", "X", "C"}, wantAt: "C",
		},
		{
			name:       "a jump after going back drops the forward side",
			pushes:     [][2]string{{"A", "B"}, {"B", "C"}},
			back:       2,
			lastOrigin: "A", lastTarget: "D",
			want: []string{"A", "D"}, wantAt: "D",
		},
		{
			name:       "a jump back onto the cursor's session keeps the forward side",
			pushes:     [][2]string{{"A", "B"}, {"B", "C"}},
			back:       1,
			lastOrigin: "B", lastTarget: "B",
			want: []string{"A", "B", "C"}, wantAt: "B",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			conn := openNavDB(t)
			for _, p := range c.pushes {
				mustPush(t, conn, p[0], p[1])
			}
			if c.back > 0 {
				hist, idx, _ := NavHistory(conn)
				if err := SetNavCursor(conn, hist[idx-c.back].Pos); err != nil {
					t.Fatal(err)
				}
			}
			mustPush(t, conn, c.lastOrigin, c.lastTarget)
			got, at := navState(t, conn)
			if !slices.Equal(got, c.want) || at != c.wantAt {
				t.Errorf("history = %v at %q, want %v at %q", got, at, c.want, c.wantAt)
			}
		})
	}
}

func TestPushNavCapsHistory(t *testing.T) {
	conn := openNavDB(t)
	var want []string
	for i := 0; i < NavLimit+5; i++ {
		id := fmt.Sprintf("s%02d", i)
		mustPush(t, conn, "", id)
		want = append(want, id)
	}
	want = want[len(want)-NavLimit:]
	got, at := navState(t, conn)
	if !slices.Equal(got, want) {
		t.Errorf("history = %v, want the newest %d: %v", got, NavLimit, want)
	}
	if at != want[len(want)-1] {
		t.Errorf("cursor at %q, want the newest", at)
	}
}

func TestSessionInPane(t *testing.T) {
	conn := openNavDB(t)
	insertSession(t, conn, "gone", "%1")
	if _, err := conn.Exec("UPDATE sessions SET terminated_at = 1 WHERE session_id = 'gone'"); err != nil {
		t.Fatal(err)
	}
	insertSession(t, conn, "live", "%2")
	for pane, want := range map[string]string{"%1": "", "%2": "live", "%9": "", "": ""} {
		got, err := SessionInPane(conn, pane)
		if err != nil || got != want {
			t.Errorf("SessionInPane(%q) = %q, %v; want %q", pane, got, err, want)
		}
	}
}
