package multiplexer

import (
	"errors"
	"os"
)

// Multiplexer abstracts the terminal multiplexer in use (tmux, Zellij, etc.).
// v0.1 implements tmux only; other implementations can be added without
// touching hook / picker callers.
type Multiplexer interface {
	// PaneID returns a stable identifier for the pane this process runs in, or
	// "". Callers that want the pane the *client* is looking at want
	// CurrentPane instead; this one must keep answering only about its own
	// process, since that is what a hook records as the session's pane.
	PaneID() string
	// CurrentPane returns the pane the client currently has focused, or "".
	// Unlike PaneID this may be answered by asking the multiplexer, so it works
	// from a context that is not itself a pane -- which is the picker's case.
	CurrentPane() string
	// RefreshStatus asks the multiplexer to redraw its status bar.
	RefreshStatus()
	// Switch focuses the pane/target identified by the string returned
	// from a prior PaneID() call.
	Switch(target string) error
	// OpenSession opens argv in a window of the multiplexer session named
	// name, creating that session if it does not exist, and moves the client
	// there. cwd is the window's working directory. window is the name to
	// give that window, which callers derive from the session's content (see
	// internal/label) -- the implementation only sanitizes it, it never
	// invents one. originPane is the pane the client is returned to once argv
	// finishes cleanly, from a prior CurrentPane() call; "" skips the return.
	// Returns an error when there is no multiplexer to open a session in.
	OpenSession(name, cwd, window, originPane string, argv []string) error
	// RenameWindow renames the window holding pane. Used to keep a window's
	// name following the conversation running in it, so it is best-effort:
	// callers ignore the error rather than fail the operation they were in.
	RenameWindow(pane, name string) error
	// SetAutomaticRename re-enables (or disables) the multiplexer's own
	// window naming for the window holding pane. Renaming a window turns
	// tmux's automatic-rename off permanently, so a session that named its
	// window has to hand the name back when it ends.
	SetAutomaticRename(pane string, on bool) error
	// WindowName returns the current name of the window holding pane.
	// Reports false when it cannot be asked, which callers must not read as
	// "the name is empty".
	WindowName(pane string) (string, bool)
	// WindowPaneCount returns how many panes share pane's window, so a caller
	// can tell whether renaming that window speaks for pane alone. Reports
	// false when it cannot be asked.
	WindowPaneCount(pane string) (int, bool)
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
func (noopImpl) CurrentPane() string        { return "" }
func (noopImpl) RefreshStatus()             {}
func (noopImpl) Switch(target string) error { return nil }

// OpenSession cannot succeed without a multiplexer, and callers need to know:
// unlike Switch, there is no silent degradation that still gets the user to
// their session. The error is what makes the caller print a manual fallback.
func (noopImpl) OpenSession(name, cwd, window, originPane string, argv []string) error {
	return errors.New("no multiplexer detected")
}

// RenameWindow and SetAutomaticRename succeed silently for the same reason
// Switch does: window naming is cosmetic, and a hook running outside tmux must
// not report a failure over it.
func (noopImpl) RenameWindow(pane, name string) error          { return nil }
func (noopImpl) SetAutomaticRename(pane string, on bool) error { return nil }

// WindowName and WindowPaneCount have no window to describe. The false is what
// keeps a caller from acting on the zero values as if they were answers.
func (noopImpl) WindowName(pane string) (string, bool)   { return "", false }
func (noopImpl) WindowPaneCount(pane string) (int, bool) { return 0, false }

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
