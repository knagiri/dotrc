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

// NewWindow opens the command in a new window and makes it current, so
// picking a background session in the picker actually takes the user there;
// -c sets the window's working directory.
func (tmuxImpl) NewWindow(cwd string, argv []string) error {
	return exec.Command("tmux", newWindowArgs(cwd, argv)...).Run()
}

// newWindowArgs builds the tmux argv. Split out from NewWindow so the
// contract can be asserted without starting a tmux server.
func newWindowArgs(cwd string, argv []string) []string {
	args := []string{"new-window"}
	if cwd != "" {
		args = append(args, "-c", cwd)
	}
	return append(args, argv...)
}
