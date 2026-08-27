package picker

import (
	"strings"
	"testing"
)

// environ builds the NUL-separated block /proc/<pid>/environ hands back.
func environ(entries ...string) string {
	return strings.Join(entries, "\x00") + "\x00"
}

// ownedBy is the socket-lookup stub the "another server" cases exercise
// classifyOrigin with, so the rule is pinned without a tmux server. pid 0
// stands for "the socket is not there"; unknownOwner is the lookup that could
// not answer at all.
func ownedBy(pid int) socketOwner {
	return func(string) (int, bool) { return pid, true }
}

func unknownOwner(string) (int, bool) { return 0, false }

// classifyOrigin is what decides whether a live session may be killed to be
// resumed, so every answer it can give is pinned here. The rule errs toward
// originUnknown -- "do not kill" -- whenever the environment does not settle
// the question, and toward originForeignLive -- also "do not kill" -- whenever
// a different tmux server still owns the socket it was started on.
func TestClassifyOrigin(t *testing.T) {
	cases := []struct {
		name             string
		environ          string
		currentServerPID int
		owner            socketOwner
		want             serverOrigin
	}{{
		name:             "same server",
		environ:          environ("PATH=/usr/bin", "TMUX=/tmp/tmux-1000/default,1234,0", "TMUX_PANE=%3"),
		currentServerPID: 1234,
		owner:            ownedBy(1234),
		want:             originCurrent,
	}, {
		// The measured majority: the process outlived the server it was
		// started in, and the socket it recorded now belongs to a different
		// server. The old pid may well still be running, but nothing can open
		// a client onto it any more.
		name:             "another server, socket taken over",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 5678,
		owner:            ownedBy(5678),
		want:             originOrphan,
	}, {
		// pid 0 from the lookup means the socket is gone entirely: nothing is
		// listening, so the same conclusion holds.
		name:             "another server, socket gone",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 5678,
		owner:            ownedBy(0),
		want:             originOrphan,
	}, {
		// tmux servers are per-socket: a different server pid does not by
		// itself mean unreachable. This one still owns its socket, so a human
		// can `tmux -L other attach` into it right now.
		name:             "another server, still owns its socket",
		environ:          environ("TMUX=/tmp/tmux-1000/other,1234,0"),
		currentServerPID: 5678,
		owner:            ownedBy(1234),
		want:             originForeignLive,
	}, {
		// The socket could not be queried at all: the safe answer is "cannot
		// tell", not "assume unreachable".
		name:             "another server, socket unqueryable",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 5678,
		owner:            unknownOwner,
		want:             originUnknown,
	}, {
		name:             "another server, no lookup available",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 5678,
		owner:            nil,
		want:             originUnknown,
	}, {
		// No TMUX at all: a terminal somewhere owns this process.
		name:             "no TMUX means outside tmux",
		environ:          environ("PATH=/usr/bin", "TERM=xterm"),
		currentServerPID: 5678,
		owner:            ownedBy(0),
		want:             originOutside,
	}, {
		// TMUX_PANE also starts with "TMUX", and reading it as the socket
		// triple would classify an outside-tmux session as unknown.
		name:             "TMUX_PANE alone is not TMUX",
		environ:          environ("TMUX_PANE=%3"),
		currentServerPID: 5678,
		owner:            ownedBy(0),
		want:             originOutside,
	}, {
		name:             "unparseable TMUX",
		environ:          environ("TMUX=nonsense"),
		currentServerPID: 5678,
		owner:            ownedBy(0),
		want:             originUnknown,
	}, {
		name:             "non-numeric server pid",
		environ:          environ("TMUX=/tmp/tmux-1000/default,notapid,0"),
		currentServerPID: 5678,
		owner:            ownedBy(0),
		want:             originUnknown,
	}, {
		// Nothing to compare against, so nothing is provably an orphan.
		name:             "no server pid of our own",
		environ:          environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		currentServerPID: 0,
		owner:            ownedBy(0),
		want:             originUnknown,
	}, {
		// The pid is the second-to-last field, so a comma in the socket path
		// does not shift the answer onto a path fragment.
		name:             "socket path containing a comma",
		environ:          environ("TMUX=/tmp/odd,dir/default,1234,0"),
		currentServerPID: 1234,
		owner:            ownedBy(0),
		want:             originCurrent,
	}, {
		name:             "empty environ",
		environ:          "",
		currentServerPID: 1234,
		owner:            ownedBy(0),
		want:             originOutside,
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := classifyOrigin(c.environ, c.currentServerPID, c.owner); got != c.want {
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

// The socket half of the TMUX triple is what the killability check queries, so
// it has to survive a path containing the separator the triple is split on.
func TestTmuxServerPID(t *testing.T) {
	cases := []struct {
		name       string
		environ    string
		wantSocket string
		wantPID    int
		wantOK     bool
	}{{
		name:       "plain path",
		environ:    environ("TMUX=/tmp/tmux-1000/default,1234,0"),
		wantSocket: "/tmp/tmux-1000/default",
		wantPID:    1234,
		wantOK:     true,
	}, {
		name:       "path containing a comma",
		environ:    environ("TMUX=/tmp/odd,dir/default,1234,7"),
		wantSocket: "/tmp/odd,dir/default",
		wantPID:    1234,
		wantOK:     true,
	}, {
		name:    "too few fields",
		environ: environ("TMUX=/tmp/tmux-1000/default,1234"),
	}, {
		name:    "no TMUX",
		environ: environ("TMUX_PANE=%3"),
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			socket, pid, ok := tmuxServerPID(c.environ)
			if ok != c.wantOK || socket != c.wantSocket || pid != c.wantPID {
				t.Errorf("tmuxServerPID = (%q, %d, %v), want (%q, %d, %v)",
					socket, pid, ok, c.wantSocket, c.wantPID, c.wantOK)
			}
		})
	}
}
