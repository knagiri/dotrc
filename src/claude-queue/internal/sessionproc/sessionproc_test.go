package sessionproc

import (
	"errors"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// A row whose tmux_pane went NULL still has a live process, and when that
// process runs in the current tmux server the picker must switch to its pane
// rather than fall through to `claude attach` -- which only serves background
// jobs and would silently close a fresh window for an interactive session.
func TestPaneForSession(t *testing.T) {
	agents := []roster.Agent{
		{SessionID: "bg", PID: 100, Kind: roster.KindBackground},
		{SessionID: "live", PID: 200, Kind: roster.KindInteractive},
	}
	// The background pid resolves to a pane, because in the field it does: a
	// background agent is forked by the host-shared `claude daemon run`
	// singleton, and when that daemon was itself started from inside a pane the
	// ancestry walk reaches it. The pane is not the session's, so the lookup
	// must not be attempted at all.
	find := func(pid int) (string, bool) {
		switch pid {
		case 100:
			return "%320", true
		case 200:
			return "%7", true
		}
		return "", false
	}

	if got := PaneForSession(agents, "live", find); got != "%7" {
		t.Errorf("PaneForSession(live) = %q, want %%7", got)
	}
	// A background session must stay empty so DecideAction routes it to attach,
	// which is the only path that reaches it -- switching would land on the
	// daemon's ancestor pane, an unrelated session's window.
	if got := PaneForSession(agents, "bg", find); got != "" {
		t.Errorf("PaneForSession(bg) = %q, want empty", got)
	}
	// A session the roster does not list is already gone; nothing to resolve.
	if got := PaneForSession(agents, "missing", find); got != "" {
		t.Errorf("PaneForSession(missing) = %q, want empty", got)
	}
	if got := PaneForSession(nil, "live", find); got != "" {
		t.Errorf("PaneForSession over an empty roster = %q, want empty", got)
	}
}

// The observed symptom, in the shape it was measured: two unrelated background
// sessions in different worktrees, both under one shared daemon, resolved to
// the same pane %320 -- which belonged to a third session's `claude attach`
// window. Both rows would have switched there instead of attaching, with no
// error. Neither may resolve to a pane.
func TestPaneForSessionSharedDaemonPane(t *testing.T) {
	agents := []roster.Agent{
		{SessionID: "6f3093ad", PID: 3843635, Kind: roster.KindBackground},
		{SessionID: "b1baa690", PID: 3118555, Kind: roster.KindBackground},
	}
	// Both pids walk up into the one pane the shared daemon was started from.
	find := func(int) (string, bool) { return "%320", true }

	for _, id := range []string{"6f3093ad", "b1baa690"} {
		if got := PaneForSession(agents, id, find); got != "" {
			t.Errorf("PaneForSession(%s) = %q, want empty: that pane belongs to the daemon's ancestor, not this session", id, got)
		}
	}
}

// The wait after a SIGTERM is what keeps a resume from opening a transcript the
// dying process is still flushing. It has to be sure the session ended, so an
// unreadable roster counts as "still there" rather than as "gone".
func TestWaitGone(t *testing.T) {
	present := []roster.Agent{{SessionID: "s", PID: 1}}
	rosterErr := errors.New("claude agents --json: exit 1")

	t.Run("absent immediately", func(t *testing.T) {
		ticks := 0
		ok := WaitGone("s", func() ([]roster.Agent, error) { return nil, nil }, func() { ticks++ }, 5)
		if !ok || ticks != 1 {
			t.Errorf("got (%v, %d ticks), want (true, 1 tick)", ok, ticks)
		}
	})

	t.Run("leaves partway through", func(t *testing.T) {
		reads := 0
		list := func() ([]roster.Agent, error) {
			reads++
			if reads < 3 {
				return present, nil
			}
			return nil, nil
		}
		if !WaitGone("s", list, func() {}, 5) {
			t.Error("WaitGone = false, want true once the session leaves the roster")
		}
	})

	t.Run("never leaves", func(t *testing.T) {
		ticks := 0
		ok := WaitGone("s", func() ([]roster.Agent, error) { return present, nil }, func() { ticks++ }, 4)
		if ok || ticks != 4 {
			t.Errorf("got (%v, %d ticks), want (false, 4 ticks)", ok, ticks)
		}
	})

	t.Run("unreadable roster is not proof of death", func(t *testing.T) {
		if WaitGone("s", func() ([]roster.Agent, error) { return nil, rosterErr }, func() {}, 3) {
			t.Error("WaitGone = true on an unreadable roster, want false")
		}
	})

	// Another session leaving does not stand in for this one.
	t.Run("other sessions do not count", func(t *testing.T) {
		other := []roster.Agent{{SessionID: "t", PID: 2}}
		if !WaitGone("s", func() ([]roster.Agent, error) { return other, nil }, func() {}, 2) {
			t.Error("WaitGone = false when only another session is listed, want true")
		}
	})
}
