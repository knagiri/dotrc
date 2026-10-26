package multiplexer

import (
	"fmt"
	"os/exec"
	"slices"
	"strconv"
	"strings"
)

// The tmux calls the watch pass needs to stop an interactive session from
// outside any pane (hibernation) and to open one again (a PR wake-up). They
// are tmux-only functions rather than Multiplexer methods: the pass runs from a
// systemd unit, where there is no $TMUX for Detect to go on, and it has nothing
// to do without tmux anyway.

// Tmux returns the tmux implementation without consulting $TMUX. A caller
// that runs outside tmux (a systemd unit) but acts on its panes uses this
// instead of Detect, which would hand it the no-op implementation.
func Tmux() Multiplexer { return tmuxImpl{} }

// WindowOf returns the id of the window holding pane.
func WindowOf(pane string) (string, error) {
	out, err := exec.Command("tmux", "display-message", "-p", "-t", pane, "#{window_id}").Output()
	if err != nil {
		return "", fmt.Errorf("tmux display-message -t %s: %w", pane, err)
	}
	w := strings.TrimSpace(string(out))
	if w == "" {
		return "", fmt.Errorf("tmux display-message -t %s: no window", pane)
	}
	return w, nil
}

// VisibleWindows returns the ids of the windows some attached client is
// showing right now -- each client's session's current window.
func VisibleWindows() (map[string]bool, error) {
	out, err := exec.Command("tmux", "list-clients", "-F", "#{window_id}").Output()
	if err != nil {
		return nil, fmt.Errorf("tmux list-clients: %w", err)
	}
	return parseWindowIDs(string(out)), nil
}

func parseWindowIDs(out string) map[string]bool {
	ids := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		if w := strings.TrimSpace(line); w != "" {
			ids[w] = true
		}
	}
	return ids
}

// KillPane closes pane. tmux closes the window with it when it was the
// window's last pane.
func KillPane(pane string) error {
	if out, err := exec.Command("tmux", "kill-pane", "-t", pane).CombinedOutput(); err != nil {
		return fmt.Errorf("tmux kill-pane -t %s: %w: %s", pane, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// SessionExists reports whether the tmux server has a session named name,
// spelled the way OpenSession spells it. No server is no session.
func SessionExists(name string) bool {
	return exec.Command("tmux", "has-session", "-t="+sanitizeSessionName(name)).Run() == nil
}

// LastAttachedSession returns the session a client was attached to most
// recently (the largest session_last_attached; one never attached counts as
// 0). A running server always has a session, because tmux exits its server
// when the last one goes, so an error here means the server could not be
// asked or has just gone.
func LastAttachedSession() (string, error) {
	out, err := exec.Command("tmux", "list-sessions", "-F", "#{session_last_attached} #{session_name}").Output()
	if err != nil {
		return "", fmt.Errorf("tmux list-sessions: %w", err)
	}
	return lastAttached(string(out))
}

func lastAttached(out string) (string, error) {
	best, bestAt := "", int64(-1)
	for _, line := range strings.Split(out, "\n") {
		at, name, ok := strings.Cut(line, " ")
		if !ok || name == "" {
			continue
		}
		n, err := strconv.ParseInt(at, 10, 64)
		if err != nil {
			n = 0
		}
		if n > bestAt {
			best, bestAt = name, n
		}
	}
	if best == "" {
		return "", fmt.Errorf("tmux list-sessions: no session")
	}
	return best, nil
}

// DetachedOpenArgs is the tmux argv (without "tmux") that opens a window named
// window running argv in the existing session name, without moving any client
// to it. It is OpenSession for a caller that has no client of its own (the
// watch pass, run from a systemd timer): a switch-client there has nothing to
// switch and would only fail, and a new-window without -d would change what a
// person attached to that session is looking at.
//
// It never creates a session. A session made from that caller would take its
// environment from the caller: tmux copies each update-environment variable
// (SSH_AUTH_SOCK among them) from the client into the new session, and one
// the caller lacks is recorded as removed, which hides the server's value
// from every window of that session. A systemd service has no SSH agent, so
// the session's windows would have none either. The caller picks a session
// that is already there instead (see LastAttachedSession).
//
// The window has no -S. With -S, tmux selects a
// same-named window instead of creating one, and "unless -d is also given in
// which case the command does nothing" (tmux(1)): the command would exit 0
// without starting claude, and the delivery would be recorded as done. So the
// window is always a new one, even if another has the same name.
//
// The names are sanitized here for the same reason OpenSession does it: every
// tmux target built from them has to agree on one spelling.
func DetachedOpenArgs(name, window, cwd string, env map[string]string, argv []string) []string {
	name, window = sanitizeSessionName(name), sanitizeWindowName(window)
	args := newWindowArgs(name, window, cwd, "", env, argv)
	i := slices.Index(args, "-S")
	return slices.Concat([]string{args[0], "-d"}, args[1:i], args[i+1:])
}
