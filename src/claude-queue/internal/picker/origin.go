package picker

import (
	"errors"
	"io/fs"
	"os"
	"os/exec"
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
	// a process that exited mid-check), the TMUX value does not parse, we have
	// no server pid of our own to compare against, or (see originForeignLive)
	// the other server's socket could not be queried. It is deliberately the
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
	// originOrphan means the process belongs to a tmux server that no longer
	// owns the socket it was started on: either the socket is gone, or another
	// server has taken the path over. Nobody can open a new client onto it, so
	// the conversation is only recoverable by ending the process and resuming
	// the transcript.
	//
	// A client that was already attached when the socket changed hands keeps
	// working over its existing connection, and there is no way left to
	// enumerate it -- the socket that would answer the question now belongs to
	// someone else. That residual risk is what the whole path trades against
	// leaving the conversation unreachable forever.
	originOrphan
	// originForeignLive means the process belongs to a tmux server that is not
	// ours but still owns its socket. tmux servers are scoped per socket
	// (`tmux -L` / `-S`), so a server we cannot switch-client into is perfectly
	// reachable by `tmux -L other attach` from another terminal, and a human
	// may be in it right now. Not killable.
	originForeignLive
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
		return "on a tmux server that no longer owns its socket"
	case originForeignLive:
		return "on another tmux server that is still reachable through its own socket"
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
	return classifyOrigin(environ, currentServerPID, socketServerPID)
}

// classifyOrigin is the rule itself, over the raw NUL-separated environment
// block, so every branch can be exercised without a live process. The socket
// lookup is injected rather than shelling out from here, so it too can be
// exercised without a tmux server.
func classifyOrigin(environ string, currentServerPID int, owner socketOwner) serverOrigin {
	socket, serverPID, ok := tmuxServerPID(environ)
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
	// A different server pid than ours is not enough on its own: tmux servers
	// are per-socket, so a server we cannot see (`tmux -L other`) can still be
	// serving clients through its own socket. The question that decides
	// killability is not whether that pid is running but whether anyone can
	// still open a client onto it -- which is answered by asking the socket the
	// session recorded who owns it now.
	//
	// Checking the pid alone would be both too strict and too lax: a server
	// whose socket was taken over lingers as a live process that nobody can
	// reach (the measured case this path exists for), while a pid that has been
	// recycled onto an unrelated process would read as "gone".
	if owner == nil {
		return originUnknown
	}
	ownerPID, ok := owner(socket)
	if !ok {
		return originUnknown
	}
	if ownerPID == serverPID {
		return originForeignLive
	}
	return originOrphan
}

// socketOwner reports the pid of the tmux server currently listening on a
// socket path. A zero pid with ok means the socket is not there at all, i.e.
// no server owns it; !ok means the question could not be answered, which
// classifyOrigin turns into "do not kill".
type socketOwner func(socket string) (int, bool)

// socketServerPID asks the server on socket for its pid.
//
// A missing socket file is an answer, not a failure: nothing is listening, so
// no client can be opened onto whatever process still holds the old pid. Any
// other stat error, or a tmux invocation that does not yield a pid, leaves the
// question unanswered.
func socketServerPID(socket string) (int, bool) {
	if socket == "" {
		return 0, false
	}
	if _, err := os.Stat(socket); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return 0, true
		}
		return 0, false
	}
	out, err := exec.Command("tmux", "-S", socket, "display", "-p", "#{pid}").Output()
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil || pid <= 0 {
		return 0, false
	}
	return pid, true
}

// tmuxServerPID splits TMUX=<socket>,<serverpid>,<n> into the socket path and
// the server pid.
//
// The pid is taken from the second-to-last comma-separated field rather than
// index 1, and the socket from everything before it, so a socket path
// containing a comma neither shifts the pid onto a path fragment nor loses its
// tail.
func tmuxServerPID(environ string) (socket string, pid int, ok bool) {
	value, found := environValue(environ, "TMUX")
	if !found {
		return "", 0, false
	}
	fields := strings.Split(value, ",")
	if len(fields) < 3 {
		return "", 0, false
	}
	pid, err := strconv.Atoi(fields[len(fields)-2])
	if err != nil || pid <= 0 {
		return "", 0, false
	}
	return strings.Join(fields[:len(fields)-2], ","), pid, true
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
