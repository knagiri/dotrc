package multiplexer

import (
	"os"
	"os/exec"
)

type tmuxImpl struct{}

func (tmuxImpl) PaneID() string {
	return os.Getenv("TMUX_PANE")
}

func (tmuxImpl) RefreshStatus() {
	_ = exec.Command("tmux", "refresh-client", "-S").Run()
}

func (tmuxImpl) Switch(target string) error {
	return exec.Command("tmux", "switch-client", "-t", target).Run()
}

// NewWindow opens the command in a detached window (-d) so the caller's pane
// keeps focus; -c sets the window's working directory.
func (tmuxImpl) NewWindow(cwd string, argv []string) error {
	args := []string{"new-window", "-d"}
	if cwd != "" {
		args = append(args, "-c", cwd)
	}
	args = append(args, argv...)
	return exec.Command("tmux", args...).Run()
}
