package multiplexer

import "os"

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
