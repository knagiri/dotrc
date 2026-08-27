package multiplexer

import (
	"errors"
	"os"
)

// Multiplexer abstracts the terminal multiplexer in use (tmux, Zellij, etc.).
// v0.1 implements tmux only; other implementations can be added without
// touching hook / picker callers.
type Multiplexer interface {
	// PaneID returns a stable identifier for the current pane, or "".
	PaneID() string
	// RefreshStatus asks the multiplexer to redraw its status bar.
	RefreshStatus()
	// Switch focuses the pane/target identified by the string returned
	// from a prior PaneID() call.
	Switch(target string) error
	// OpenSession opens argv in a window of the multiplexer session named
	// name, creating that session if it does not exist, and moves the client
	// there. cwd is the window's working directory. Returns an error when
	// there is no multiplexer to open a session in.
	OpenSession(name, cwd string, argv []string) error
	// FindPane returns the pane pid is running in, walking up the process
	// tree until a pane matches, so a process started deeper than the pane's
	// own shell is still located. Reports false when there is no such pane --
	// including when the multiplexer cannot be queried at all, since neither
	// case gives the caller a pane to switch to.
	FindPane(pid int) (string, bool)
	// PaneExists reports whether target is still a pane of the server this
	// process talks to. False also covers "could not ask", for the same reason
	// as FindPane: either way the caller has no pane it can switch to.
	PaneExists(target string) bool
	// ServerPID returns the pid of the multiplexer server process, so a
	// caller can tell a pane of this server from a pane of another one.
	// Reports false when there is no server to ask.
	ServerPID() (int, bool)
}

// Detect selects an implementation based on environment variables.
// Falls back to a silent no-op when no multiplexer is detected.
func Detect() Multiplexer {
	if os.Getenv("TMUX") != "" {
		return tmuxImpl{}
	}
	// Future: if os.Getenv("ZELLIJ") != "" { return zellijImpl{} }
	return noopImpl{}
}

// noopImpl is returned when no multiplexer is detected. All methods
// succeed silently so hooks stay functional outside tmux/zellij.
type noopImpl struct{}

func (noopImpl) PaneID() string             { return "" }
func (noopImpl) RefreshStatus()             {}
func (noopImpl) Switch(target string) error { return nil }

// OpenSession cannot succeed without a multiplexer, and callers need to know:
// unlike Switch, there is no silent degradation that still gets the user to
// their session. The error is what makes the caller print a manual fallback.
func (noopImpl) OpenSession(name, cwd string, argv []string) error {
	return errors.New("no multiplexer detected")
}

// FindPane has no panes to search without a multiplexer. Unlike OpenSession this
// needs no error: "not found" is already the answer the caller acts on.
func (noopImpl) FindPane(pid int) (string, bool) { return "", false }

// PaneExists is false for the same reason: with no server to ask, no pane the
// caller was handed can be confirmed to still be there.
func (noopImpl) PaneExists(target string) bool { return false }

// ServerPID has no server, which is exactly what the false reports. Callers use
// it to decide whether a session's pane lives elsewhere; without a server of our
// own there is nothing to compare against.
func (noopImpl) ServerPID() (int, bool) { return 0, false }
