package hibernate

import (
	"errors"
	"fmt"

	"github.com/knagiri/dotrc/src/claude-queue/internal/multiplexer"
	"github.com/knagiri/dotrc/src/claude-queue/internal/reconcile"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
	"github.com/knagiri/dotrc/src/claude-queue/internal/sessionproc"
)

// Deps is every effect Hibernate has on the world. Hibernate never fills in a
// missing one, so a test that leaves a field nil fails on the nil call rather
// than reaching a real process or a real tmux server; RealDeps is the only
// place the real ones are wired.
type Deps struct {
	// FindPane resolves the pane a pid runs in (multiplexer FindPane).
	FindPane func(pid int) (string, bool)
	// WindowOf returns the window id holding a pane.
	WindowOf func(pane string) (string, error)
	// VisibleWindows returns the window ids attached clients are showing.
	VisibleWindows func() (map[string]bool, error)
	// End SIGTERMs pid and waits for cfgDir's roster to drop sessionID; an
	// error means it is still listed, or the signal failed.
	End func(pid int, sessionID, cfgDir string) error
	// PaneExists reports whether a pane is still there.
	PaneExists func(pane string) bool
	// KillPane closes a pane (and its window, when it is the last pane).
	KillPane func(pane string) error
	// Stop stops a background session (`claude stop`) under its config dir.
	Stop func(dir, sessionID string) error
}

// RealDeps wires Deps to tmux, signals and `claude stop`.
func RealDeps() Deps {
	mux := multiplexer.Tmux()
	return Deps{
		FindPane:       mux.FindPane,
		WindowOf:       multiplexer.WindowOf,
		VisibleWindows: multiplexer.VisibleWindows,
		End:            sessionproc.End,
		PaneExists:     mux.PaneExists,
		KillPane:       multiplexer.KillPane,
		Stop:           reconcile.StopIn,
	}
}

// SkipError is a Hibernate that decided not to act. Nothing was stopped.
type SkipError struct{ Reason string }

func (e *SkipError) Error() string { return e.Reason }

// IsSkip reports whether err is a SkipError, i.e. Hibernate left the session
// alone on purpose rather than failing partway.
func IsSkip(err error) bool {
	var s *SkipError
	return errors.As(err, &s)
}

// Hibernate stops c's process, leaving its work open.
//
// A background session is stopped with `claude stop`. An interactive one is
// SIGTERM'd and, once its config dir's roster no longer lists it, its pane is
// closed: a resume opens a fresh window, so the shell the pane falls back to
// would only be clutter. The pane is resolved from the process, never from the
// ledger, whose recorded id can belong to a since-replaced tmux server.
//
// It is skipped, with nothing stopped, when
//   - no pane can be found for the process (started outside tmux, or under
//     another tmux server): closing it would leave nothing for the person to
//     find, and stopping it without the pane would leave an empty shell
//     behind in some unknown place;
//   - the pane's window is on screen in an attached client. Someone is looking
//     at it, whatever the idle clock says.
//
// A session still listed 10s after the SIGTERM is reported as an error with
// its pane left open: it was not stopped, and closing the pane would kill it
// without the transcript flush the SIGTERM was meant to allow.
func Hibernate(c Candidate, deps Deps) error {
	pane, err := check(c, deps)
	if err != nil {
		return err
	}
	if c.Kind == roster.KindBackground {
		return deps.Stop(c.ConfigDir, c.SessionID)
	}
	if err := deps.End(c.PID, c.SessionID, c.ConfigDir); err != nil {
		return fmt.Errorf("%w; pane %s left open", err, pane)
	}
	if deps.PaneExists(pane) {
		if err := deps.KillPane(pane); err != nil {
			return fmt.Errorf("process stopped, but closing pane %s failed: %w", pane, err)
		}
	}
	return nil
}

// Check runs Hibernate's skip decisions without stopping anything, for a dry
// run: it only reads tmux. A nil error means Hibernate would go on to stop c.
func Check(c Candidate, deps Deps) error {
	_, err := check(c, deps)
	return err
}

// check is the read-only half of Hibernate. It returns the pane an interactive
// session runs in ("" for a background one), or a SkipError.
func check(c Candidate, deps Deps) (string, error) {
	switch c.Kind {
	case roster.KindBackground:
		return "", nil
	case roster.KindInteractive:
	default:
		return "", &SkipError{Reason: fmt.Sprintf("unknown kind %q", c.Kind)}
	}
	pane, ok := deps.FindPane(c.PID)
	if !ok {
		return "", &SkipError{Reason: fmt.Sprintf("no tmux pane for pid %d (started outside tmux, or under another server)", c.PID)}
	}
	window, err := deps.WindowOf(pane)
	if err != nil {
		return "", &SkipError{Reason: fmt.Sprintf("window of pane %s unknown: %v", pane, err)}
	}
	visible, err := deps.VisibleWindows()
	if err != nil {
		return "", &SkipError{Reason: fmt.Sprintf("cannot tell whether pane %s is on screen: %v", pane, err)}
	}
	if visible[window] {
		return "", &SkipError{Reason: fmt.Sprintf("pane %s is on screen in an attached client", pane)}
	}
	return pane, nil
}
