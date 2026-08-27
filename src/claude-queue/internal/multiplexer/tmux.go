package multiplexer

import (
	"errors"
	"os"
	"os/exec"
	"strings"
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

// OpenSession puts argv in a window of the tmux session called name, creating
// that session when it is missing, then moves the client there. The picker
// needs the session, not just the window: a background session belongs to a
// worktree, and opening its window wherever the popup happened to be invoked
// from would scatter unrelated worktrees across one session.
func (tmuxImpl) OpenSession(name, cwd string, argv []string) error {
	if name == "" {
		return errors.New("no session name")
	}
	// Sanitize here, not in the caller: this is the tmux-specific target
	// escaping rule (see sanitizeSessionName), so it belongs with the other
	// tmux implementation, not leaked across the Multiplexer interface. Every
	// tmux invocation below must see the same sanitized name has-session
	// checks, so this has to run before any of them.
	name = sanitizeSessionName(name)
	window := windowName(argv)
	if err := exec.Command("tmux", "has-session", "-t="+name).Run(); err != nil {
		// A new session must be created detached. The picker runs inside
		// `display-popup -E`, and an attaching new-session would try to take
		// over that popup's terminal; switch-client below moves the client
		// deliberately instead. This is why -d is right here and wrong for
		// new-window, where it would leave the pick looking like a no-op.
		if err := exec.Command("tmux", newSessionArgs(name, window, cwd, argv)...).Run(); err != nil {
			return err
		}
	} else if err := exec.Command("tmux", newWindowArgs(name, window, cwd, argv)...).Run(); err != nil {
		return err
	}
	return exec.Command("tmux", "switch-client", "-t="+name).Run()
}

// newSessionArgs builds the tmux argv for creating the session. Split out from
// OpenSession so the contract can be asserted without starting a tmux server.
//
// -n names the initial window explicitly with the same windowName(argv) used
// by newWindowArgs below. Without it tmux auto-names the window from the
// shell command, which does not match the name newWindowArgs' -S looks for,
// so a session created via this path would never dedupe on a second pick of
// the same target (a second window would stack instead of -S selecting the
// first one). Naming it here also disables tmux's automatic-rename for the
// window, so the name -S depends on cannot drift later.
func newSessionArgs(name, window, cwd string, argv []string) []string {
	args := []string{"new-session", "-d", "-s", name, "-n", window}
	if cwd != "" {
		args = append(args, "-c", cwd)
	}
	return append(args, argv...)
}

// newWindowArgs builds the tmux argv for adding a window to an existing
// session. The "=" prefix on the target is required: without it tmux also
// tries prefix and glob matches, so a session named `dotrc` would ambiguously
// match `dotrc_queue-picker-worktree-session` and grow the window in the wrong
// place. The target's empty window name (the trailing ":") asks for the next
// unused index -- naming an index instead would error out once it is taken.
// -S selects an existing window of the same name rather than stacking another,
// so picking the same session twice is idempotent.
func newWindowArgs(name, window, cwd string, argv []string) []string {
	args := []string{"new-window", "-S", "-n", window, "-t", "=" + name + ":"}
	if cwd != "" {
		args = append(args, "-c", cwd)
	}
	return append(args, argv...)
}

// windowName derives a window name from the command being run, so repeated
// picks of the same target collapse onto one window (see -S above) while two
// different sessions opened in the same tmux session stay apart. Anything
// outside [A-Za-z0-9_-] becomes "_": tmux reads "." and ":" as the
// window.pane and session:window separators in -t targets.
func windowName(argv []string) string {
	if len(argv) == 0 {
		return "cmd"
	}
	var b strings.Builder
	for i, a := range argv {
		if i > 0 {
			b.WriteByte('-')
		}
		for _, r := range a {
			switch {
			case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '-':
				b.WriteRune(r)
			default:
				b.WriteByte('_')
			}
		}
	}
	return b.String()
}

// sanitizeSessionName makes a worktree directory name usable as a tmux target.
//
// tmux does not reject "." or ":" in `new-session -s`; it silently rewrites
// them to "_", which is worse than rejecting them: the session would exist
// under a name that the `has-session -t=` lookup never matches ("." is read as
// the window.pane separator), so every pick would create yet another session.
// Substituting up front keeps the name we ask for and the name tmux stores
// identical. claude-worktree already uses "_" as its separator for this reason.
func sanitizeSessionName(name string) string {
	return strings.NewReplacer(".", "_", ":", "_").Replace(name)
}
