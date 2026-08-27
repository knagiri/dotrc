package picker

import (
	"strings"
	"testing"
)

// environ builds the NUL-separated block /proc/<pid>/environ hands back.
func environ(entries ...string) string {
	return strings.Join(entries, "\x00") + "\x00"
}

// classifyOrigin is what decides whether a live session may be killed to be
// resumed, so every answer it can give is pinned here. The rule errs toward
// originUnknown -- "do not kill" -- whenever the environment does not settle
// the question.
func TestClassifyOrigin(t *testing.T) {
	cases := []struct {
		name             string
		environ          string
		currentServerPID int
		want             serverOrigin
	}{{
		name:             "same server",
		environ:          environ("PATH=/usr/bin", "TMUX=/tmp/tmux-1000/default,1234,0", "TMUX_PANE=%3"),
		currentServerPID: 1234,
		want:             originCurrent,
	}, {
		// The measured majority: the process outlived the tmux server it was
		// started in, so no client of ours can ever reach its pane.
		name:             "another server",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 5678,
		want:             originOrphan,
	}, {
		// No TMUX at all: a terminal somewhere owns this process.
		name:             "no TMUX means outside tmux",
		environ:          environ("PATH=/usr/bin", "TERM=xterm"),
		currentServerPID: 5678,
		want:             originOutside,
	}, {
		// TMUX_PANE also starts with "TMUX", and reading it as the socket
		// triple would classify an outside-tmux session as unknown.
		name:             "TMUX_PANE alone is not TMUX",
		environ:          environ("TMUX_PANE=%3"),
		currentServerPID: 5678,
		want:             originOutside,
	}, {
		name:             "unparseable TMUX",
		environ:          environ("TMUX=nonsense"),
		currentServerPID: 5678,
		want:             originUnknown,
	}, {
		name:             "non-numeric server pid",
		environ:          environ("TMUX=/tmp/tmux-1000/default,notapid,0"),
		currentServerPID: 5678,
		want:             originUnknown,
	}, {
		// Nothing to compare against, so nothing is provably an orphan.
		name:             "no server pid of our own",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 0,
		want:             originUnknown,
	}, {
		// The pid is the second-to-last field, so a comma in the socket path
		// does not shift the answer onto a path fragment.
		name:             "socket path containing a comma",
		environ:          environ("TMUX=/tmp/odd,dir/default,1234,0"),
		currentServerPID: 1234,
		want:             originCurrent,
	}, {
		name:             "empty environ",
		environ:          "",
		currentServerPID: 1234,
		want:             originOutside,
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := classifyOrigin(c.environ, c.currentServerPID); got != c.want {
				t.Errorf("classifyOrigin = %v, want %v", got, c.want)
			}
		})
	}
}

// Only originOrphan may be killed, and DecideAction leans on that. If a new
// value is ever added, this makes the omission visible rather than silently
// widening the kill.
func TestOnlyOrphanIsKillable(t *testing.T) {
	for _, o := range []serverOrigin{originUnknown, originOutside, originCurrent} {
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
	for _, o := range []serverOrigin{originUnknown, originOutside, originCurrent, originOrphan} {
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
