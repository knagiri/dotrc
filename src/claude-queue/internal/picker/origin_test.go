package picker

import (
	"strings"
	"testing"
)

// environ builds the NUL-separated block /proc/<pid>/environ hands back.
func environ(entries ...string) string {
	return strings.Join(entries, "\x00") + "\x00"
}

// alwaysAlive and neverAlive are the liveness stubs the "another server"
// cases exercise classifyOrigin with, so the rule is pinned without touching
// a real /proc.
func alwaysAlive(int) bool { return true }
func neverAlive(int) bool  { return false }

// classifyOrigin is what decides whether a live session may be killed to be
// resumed, so every answer it can give is pinned here. The rule errs toward
// originUnknown -- "do not kill" -- whenever the environment does not settle
// the question, and toward originForeignLive -- also "do not kill" -- whenever
// a different tmux server's liveness cannot be ruled out.
func TestClassifyOrigin(t *testing.T) {
	cases := []struct {
		name             string
		environ          string
		currentServerPID int
		alive            func(int) bool
		want             serverOrigin
	}{{
		name:             "same server",
		environ:          environ("PATH=/usr/bin", "TMUX=/tmp/tmux-1000/default,1234,0", "TMUX_PANE=%3"),
		currentServerPID: 1234,
		alive:            neverAlive,
		want:             originCurrent,
	}, {
		// The measured majority: the process outlived the tmux server it was
		// started in, and that server's pid is confirmed gone, so no client --
		// ours or anyone else's -- can ever reach its pane again.
		name:             "another server, confirmed dead",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 5678,
		alive:            neverAlive,
		want:             originOrphan,
	}, {
		// tmux servers are per-socket: a different server pid does not by
		// itself mean unreachable. If that server's pid is still running, a
		// human may be attached to it from another terminal via `tmux -L`/`-S`
		// right now, so it must not be killed.
		name:             "another server, still running",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 5678,
		alive:            alwaysAlive,
		want:             originForeignLive,
	}, {
		// Liveness of the other server could not be determined at all: the
		// safe answer is the same as "cannot tell", not "assume dead".
		name:             "another server, liveness undeterminable",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 5678,
		alive:            nil,
		want:             originUnknown,
	}, {
		// No TMUX at all: a terminal somewhere owns this process.
		name:             "no TMUX means outside tmux",
		environ:          environ("PATH=/usr/bin", "TERM=xterm"),
		currentServerPID: 5678,
		alive:            neverAlive,
		want:             originOutside,
	}, {
		// TMUX_PANE also starts with "TMUX", and reading it as the socket
		// triple would classify an outside-tmux session as unknown.
		name:             "TMUX_PANE alone is not TMUX",
		environ:          environ("TMUX_PANE=%3"),
		currentServerPID: 5678,
		alive:            neverAlive,
		want:             originOutside,
	}, {
		name:             "unparseable TMUX",
		environ:          environ("TMUX=nonsense"),
		currentServerPID: 5678,
		alive:            neverAlive,
		want:             originUnknown,
	}, {
		name:             "non-numeric server pid",
		environ:          environ("TMUX=/tmp/tmux-1000/default,notapid,0"),
		currentServerPID: 5678,
		alive:            neverAlive,
		want:             originUnknown,
	}, {
		// Nothing to compare against, so nothing is provably an orphan.
		name:             "no server pid of our own",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 0,
		alive:            neverAlive,
		want:             originUnknown,
	}, {
		// The pid is the second-to-last field, so a comma in the socket path
		// does not shift the answer onto a path fragment.
		name:             "socket path containing a comma",
		environ:          environ("TMUX=/tmp/odd,dir/default,1234,0"),
		currentServerPID: 1234,
		alive:            neverAlive,
		want:             originCurrent,
	}, {
		name:             "empty environ",
		environ:          "",
		currentServerPID: 1234,
		alive:            neverAlive,
		want:             originOutside,
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := classifyOrigin(c.environ, c.currentServerPID, c.alive); got != c.want {
				t.Errorf("classifyOrigin = %v, want %v", got, c.want)
			}
		})
	}
}

// Only originOrphan may be killed, and DecideAction leans on that. If a new
// value is ever added, this makes the omission visible rather than silently
// widening the kill.
func TestOnlyOrphanIsKillable(t *testing.T) {
	for _, o := range []serverOrigin{originUnknown, originOutside, originCurrent, originForeignLive} {
		tgt := resumable()
		tgt.InRoster, tgt.Kind, tgt.PID, tgt.Origin = true, "interactive", 4242, o
		if act := DecideAction(tgt); act.KillPID != 0 {
			t.Errorf("origin %v: KillPID = %d, want 0", o, act.KillPID)
		}
	}
}

// readEnviron must report failure rather than an empty block for a pid that is
// not there: an empty block would classify as originOutside, and "cannot tell"
// is the only honest answer.
func TestReadEnvironMissingPID(t *testing.T) {
	if _, ok := readEnviron(0); ok {
		t.Error("readEnviron(0) reported success, want failure")
	}
	if _, ok := readEnviron(-1); ok {
		t.Error("readEnviron(-1) reported success, want failure")
	}
	// originOf turns any read failure into originUnknown.
	if got := originOf(0, 1234); got != originUnknown {
		t.Errorf("originOf with an unreadable pid = %v, want originUnknown", got)
	}
}

// The origin appears in the stderr line explaining why a pick did not resume,
// so each value needs its own words.
func TestServerOriginString(t *testing.T) {
	seen := map[string]bool{}
	for _, o := range []serverOrigin{originUnknown, originOutside, originCurrent, originOrphan, originForeignLive} {
		s := o.String()
		if s == "" {
			t.Errorf("origin %d has no description", o)
		}
		if seen[s] {
			t.Errorf("origin %d reuses the description %q", o, s)
		}
		seen[s] = true
	}
}
