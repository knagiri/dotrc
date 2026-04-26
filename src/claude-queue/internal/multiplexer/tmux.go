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
