package hook

import (
	"github.com/knagiri/dotrc/src/claude-queue/internal/label"
)

// windowMux is the slice of multiplexer.Multiplexer the window naming needs.
// Narrowing it here is what lets the guard below be tested with a recorder
// instead of a tmux server.
type windowMux interface {
	RenameWindow(pane, name string) error
	SetAutomaticRename(pane string, on bool) error
	WindowName(pane string) (string, bool)
	WindowPaneCount(pane string) (int, bool)
}

// applyWindowName keeps the tmux window a session runs in named after what the
// session is about.
//
// It is wired to UserPromptSubmit and Stop, and nothing else. UserPromptSubmit
// is the moment the topic can change; Stop is the moment right after the first
// answer, which is when Claude Code first writes an ai-title -- without it a
// session would carry its fallback name until the user typed a second prompt.
// The other events add nothing: they fire many times per turn and would only
// re-derive the same name.
//
// Everything here is best-effort and silent. Run swallows hook errors on
// purpose (a hook must never be why a session misbehaves), and a window name is
// the least important thing in this program.
func applyWindowName(mux windowMux, event, pane, transcriptPath, sessionID string) {
	if pane == "" {
		return // a background session has no pane, and nothing to rename
	}
	switch event {
	case "UserPromptSubmit", "Stop":
		if !ownsWindow(mux, pane) {
			return
		}
		name := label.Resolve(transcriptPath, sessionID)
		if name == "" {
			return // nothing better than whatever the window is called now
		}
		_ = mux.RenameWindow(pane, name)
	case "SessionEnd":
		releaseWindowName(mux, pane, transcriptPath, sessionID)
	}
}

// ownsWindow reports whether pane is the only pane in its window, which is the
// condition for this session to speak for the window's name.
//
// Two claude sessions split side by side would otherwise rename the shared
// window on every prompt each, and the name would flip between two topics with
// no relation to which pane the user is looking at. Keeping the multiplexer's
// own name in that case is the honest answer.
//
// A count that could not be read is treated as "not ours": the guard exists to
// avoid taking a name that is not this session's to take, so the unknown case
// has to fall on the side of not renaming.
func ownsWindow(mux windowMux, pane string) bool {
	n, ok := mux.WindowPaneCount(pane)
	return ok && n == 1
}

// releaseWindowName hands the window name back to tmux when the session that
// took it ends.
//
// tmux turns automatic-rename off for a window the moment anything renames it
// ("This flag is automatically disabled for an individual window when a name is
// specified at creation with new-window or new-session, or later with
// rename-window" -- man tmux), and never turns it back on. Without this the
// title of a finished conversation would sit on top of the shell the user goes
// back to working in, for as long as that window lives.
//
// The name is compared first so only a name this session installed is given
// back: a window the user renamed by hand, or one the picker's exit rename has
// already moved to "<name>~exited", must keep the name it has.
func releaseWindowName(mux windowMux, pane, transcriptPath, sessionID string) {
	current, ok := mux.WindowName(pane)
	if !ok || current == "" {
		return
	}
	if current != label.Resolve(transcriptPath, sessionID) {
		return
	}
	_ = mux.SetAutomaticRename(pane, true)
}
