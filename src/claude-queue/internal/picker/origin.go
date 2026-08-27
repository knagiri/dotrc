package picker

import (
	"os"
	"strconv"
	"strings"
)

// serverOrigin says where the tmux server of a live session's process is,
// relative to the server the picker itself is talking to.
//
// It exists to answer one question: may this session be killed so its
// conversation can be reopened with `claude --resume`? Only originOrphan may.
// An interactive session whose pane cannot be reached is otherwise indistinguishable
// from one a human is using in another terminal right now, and resuming a session
// whose process is still alive leaves two processes writing one transcript.
type serverOrigin int

const (
	// originUnknown is the answer whenever the question could not be settled:
	// /proc is unreadable (a non-Linux host, a process owned by someone else,
	// a process that exited mid-check), the TMUX value does not parse, or we
	// have no server pid of our own to compare against. It is deliberately the
	// zero value, so a Target left unfilled defaults to "do not kill".
	originUnknown serverOrigin = iota
	// originOutside means the process has no TMUX in its environment: it was
	// started outside a multiplexer altogether. Not an orphan -- there is a
	// terminal somewhere that owns it.
	originOutside
	// originCurrent means the process belongs to this very tmux server. Its
	// pane should have been found by FindPane; seeing this alongside an
	// unreachable pane means the pane closed while the process lived on.
	originCurrent
	// originOrphan means the process belongs to a tmux server that is not
	// ours. No client of ours can ever reach it, so the conversation is only
	// recoverable by ending the process and resuming the transcript.
	originOrphan
)

// String renders the origin for the stderr message explaining why a pick did
// not resume, which is the only place these values are shown.
func (o serverOrigin) String() string {
	switch o {
	case originOutside:
		return "started outside tmux"
	case originCurrent:
		return "on this tmux server, but its pane is gone"
	case originOrphan:
		return "on another tmux server"
	default:
		return "on an unknown tmux server"
	}
}

// originOf classifies the tmux server of pid against currentServerPID, reading
// the process environment from /proc.
//
// A read failure is originUnknown rather than an error: every caller would turn
// the error into the same "cannot tell, so do not kill" decision anyway.
func originOf(pid, currentServerPID int) serverOrigin {
	environ, ok := readEnviron(pid)
	if !ok {
		return originUnknown
	}
	return classifyOrigin(environ, currentServerPID)
}

// classifyOrigin is the rule itself, over the raw NUL-separated environment
// block, so every branch can be exercised without a live process.
func classifyOrigin(environ string, currentServerPID int) serverOrigin {
	serverPID, ok := tmuxServerPID(environ)
	if !ok {
		// No TMUX at all means "outside tmux"; a TMUX that does not parse
		// means we simply do not know. tmuxServerPID reports both as false, so
		// the two are told apart by whether the variable is present.
		if hasTMUX(environ) {
			return originUnknown
		}
		return originOutside
	}
	if currentServerPID <= 0 {
		return originUnknown
	}
	if serverPID == currentServerPID {
		return originCurrent
	}
	return originOrphan
}

// tmuxServerPID pulls the server pid out of TMUX=<socket>,<serverpid>,<n>.
//
// The pid is taken from the second-to-last comma-separated field rather than
// index 1, so a socket path containing a comma does not shift the answer to a
// path fragment.
func tmuxServerPID(environ string) (int, bool) {
	value, ok := environValue(environ, "TMUX")
	if !ok {
		return 0, false
	}
	fields := strings.Split(value, ",")
	if len(fields) < 3 {
		return 0, false
	}
	pid, err := strconv.Atoi(fields[len(fields)-2])
	if err != nil || pid <= 0 {
		return 0, false
	}
	return pid, true
}

func hasTMUX(environ string) bool {
	_, ok := environValue(environ, "TMUX")
	return ok
}

// environValue finds one variable in a NUL-separated environment block.
//
// The entries are matched whole, not by substring: TMUX_PANE also starts with
// "TMUX" and would otherwise be read as the socket triple.
func environValue(environ, key string) (string, bool) {
	for _, entry := range strings.Split(environ, "\x00") {
		name, value, ok := strings.Cut(entry, "=")
		if ok && name == key {
			return value, true
		}
	}
	return "", false
}

// readEnviron reads pid's environment block. False covers every reason it could
// not be had -- no /proc on this platform, a process owned by another user, a
// process that has already exited -- because the caller treats them alike.
func readEnviron(pid int) (string, bool) {
	if pid <= 0 {
		return "", false
	}
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/environ")
	if err != nil {
		return "", false
	}
	return string(data), true
}
