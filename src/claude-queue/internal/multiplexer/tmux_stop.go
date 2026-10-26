package multiplexer

import (
	"fmt"
	"os/exec"
	"strings"
)

// The tmux calls hibernation needs to stop an interactive session from
// outside any pane. They are tmux-only functions rather than Multiplexer
// methods: hibernation runs from a systemd unit, where there is no $TMUX for
// Detect to go on, and it has nothing to do without tmux anyway.

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
