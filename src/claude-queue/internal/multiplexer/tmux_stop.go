package multiplexer

import (
	"fmt"
	"os/exec"
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

// DetachedOpenArgs is the tmux argv (without "tmux") that opens a window named
// window running argv in session name -- creating the session when exists is
// false -- without moving any client to it. It is OpenSession for a caller that
// has no client of its own (the watch pass, run from a systemd timer): a
// switch-client there has nothing to switch and would only fail, and a
// new-window without -d would change what a person attached to that session is
// looking at.
//
// The names are sanitized here for the same reason OpenSession does it: every
// tmux target built from them has to agree on one spelling.
func DetachedOpenArgs(name, window, cwd string, env map[string]string, argv []string, exists bool) []string {
	name, window = sanitizeSessionName(name), sanitizeWindowName(window)
	if !exists {
		return newSessionArgs(name, window, cwd, "", env, argv)
	}
	args := newWindowArgs(name, window, cwd, "", env, argv)
	return append([]string{args[0], "-d"}, args[1:]...)
}
