package multiplexer

import (
	"errors"
	"os"
	"os/exec"
	"strconv"
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
func (tmuxImpl) OpenSession(name, cwd, window string, argv []string) error {
	if name == "" {
		return errors.New("no session name")
	}
	// Sanitize here, not in the caller: this is the tmux-specific target
	// escaping rule (see sanitizeSessionName), so it belongs with the other
	// tmux implementation, not leaked across the Multiplexer interface. Every
	// tmux invocation below must see the same sanitized name has-session
	// checks, so this has to run before any of them.
	name = sanitizeSessionName(name)
	// Same reasoning for the window name, and the same "before every use"
	// requirement: -n, -S and the rename inside windowCommand all have to
	// agree on one spelling or the dedupe stops matching.
	window = sanitizeWindowName(window)
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
// -n names the initial window explicitly with the same window name passed to
// newWindowArgs below. Without it tmux auto-names the window from the
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
	return append(args, windowCommand(window, argv)...)
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
	return append(args, windowCommand(window, argv)...)
}

// exitedSuffix marks a window whose command has finished and which now holds
// nothing but the fallback shell. sanitizeWindowName never emits "~", so a
// renamed window can never collide with the name a later pick asks -S for --
// which is the whole point of the rename, see windowCommand.
const exitedSuffix = "~exited"

// windowCommand renders argv as the one trailing argument tmux runs in the new
// window. Passing a single argument matters: tmux runs a lone argument through
// a shell and execs a multi-argument one directly, and only the shell form can
// keep the pane alive past the command.
//
// Without it the pane's process is `claude attach` itself, so there is nothing
// to fall back to. `claude attach --help` promises "Ctrl+Z drops back to your
// shell", but Ctrl+Z ends the attach, which closes the pane, which closes the
// window -- and a session the picker just created owns only that window, so the
// whole session disappears with it. `exec`ing a shell afterwards gives Ctrl+Z
// somewhere to land. It also makes a command that fails immediately readable:
// `tmux new-window` does not surface the command's exit status, so before this
// the error scrolled past with the closing window.
//
// The rename in between is what keeps that surviving window from swallowing the
// next pick. newWindowArgs' -S selects an existing window of the same name
// *instead of* running the command, which was harmless while the window died
// with the command: -S never found a stale one. Once the window outlives the
// command, picking the same target again would land the user in the leftover
// shell and never re-run `claude attach`. Renaming on the way out releases the
// name, so -S still collapses repeat picks while claude is actually running
// there, and a pick after it exited gets a fresh window. A tmux that cannot be
// reached here just leaves the name in place; the ";" chain still reaches exec.
//
// Empty argv yields no argument at all, which is how tmux is asked for the
// default-command (an empty one, the default, starts default-shell as a login
// shell). The wrapper below is not that: it execs $SHELL without -l, so the
// fallback is interactive but not a login shell. Nothing here depends on the
// difference -- the pane only has to stay open and read a shell's rc.
func windowCommand(window string, argv []string) []string {
	if len(argv) == 0 {
		return nil
	}
	quoted := make([]string, 0, len(argv))
	for _, a := range argv {
		quoted = append(quoted, shellQuote(a))
	}
	// -t "$TMUX_PANE" addresses the pane this command runs in, rather than
	// whichever window the client happens to have current by then.
	return []string{strings.Join(quoted, " ") +
		`; tmux rename-window -t "$TMUX_PANE" ` + shellQuote(window+exitedSuffix) +
		`; exec "${SHELL:-/bin/bash}"`}
}

// shellQuote renders s as a single literal word for a POSIX shell. argv reaches
// here from the ledger (session ids, and cwd-derived values in the future), so
// the values are data rather than anything this package chose; splicing them
// into a command string unquoted would let a space or a quote in one of them
// change what runs.
//
// Single quotes suspend every other form of expansion, so the only character
// needing care is the single quote itself: it cannot be escaped inside single
// quotes, and is instead spliced in as a backslash-escaped quote between two
// quoted runs.
//
// The shell reading this is tmux's default-shell, not necessarily /bin/sh, so
// "POSIX shell" is an assumption rather than a guarantee. It holds for every
// Bourne-family shell; a csh or fish login shell would reject the ${SHELL:-...}
// form above regardless of the quoting, which is a pre-existing limit of
// running commands through tmux rather than something this quoting can fix.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// sanitizeWindowName is the last gate before a caller-supplied name reaches
// tmux. internal/label already produces names in this shape, so this is a
// backstop rather than the formatting step -- which is why it substitutes and
// trims but deliberately does not truncate: shortening a name twice, under two
// different width rules, would make the -n / -S / rename spellings disagree.
//
// "." and ":" are the window.pane and session:window separators in -t targets.
// "~" is reserved for exitedSuffix. "#" is tmux's format-expansion marker for
// the very argument this feeds -- rename-window and new-window -n both expand
// "#S"/"#T"/"#D"/"#W"/"#{...}" in the name they are given (confirmed against
// tmux 3.6b), so a "#" left in would make the name tmux stores diverge from
// the one -S/-n/rename-window agreed on. A leading "-" would be read as an
// option by tmux's argument parser, and a trailing one is just a dangling
// separator. Empty falls back to "cmd", so tmux is never handed an unnamed
// window.
func sanitizeWindowName(name string) string {
	name = strings.Trim(strings.NewReplacer(".", "-", ":", "-", "~", "-", "#", "-").Replace(name), "-")
	if name == "" {
		return "cmd"
	}
	return name
}

// RenameWindow renames the window pane belongs to. Passing a pane id where
// tmux expects a target-window is deliberate and supported: tmux resolves it
// to the window that contains the pane, which is what lets a hook rename "its"
// window while knowing only $TMUX_PANE.
func (tmuxImpl) RenameWindow(pane, name string) error {
	return exec.Command("tmux", renameWindowArgs(pane, sanitizeWindowName(name))...).Run()
}

func renameWindowArgs(pane, name string) []string {
	return []string{"rename-window", "-t", pane, name}
}

// SetAutomaticRename hands the window's name back to tmux (or takes it away).
// tmux disables automatic-rename for a window as soon as anything names it
// explicitly -- `new-window -n`, `rename-window` -- and never re-enables it on
// its own, so without this the last name a session set would outlive it and
// sit on top of the shell that takes the pane over.
func (tmuxImpl) SetAutomaticRename(pane string, on bool) error {
	return exec.Command("tmux", automaticRenameArgs(pane, on)...).Run()
}

func automaticRenameArgs(pane string, on bool) []string {
	value := "off"
	if on {
		value = "on"
	}
	return []string{"setw", "-t", pane, "automatic-rename", value}
}

// WindowName returns the name of the window pane belongs to.
func (tmuxImpl) WindowName(pane string) (string, bool) {
	out, err := exec.Command("tmux", windowNameArgs(pane)...).Output()
	if err != nil {
		return "", false
	}
	return strings.TrimRight(string(out), "\n"), true
}

func windowNameArgs(pane string) []string {
	return []string{"display", "-p", "-t", pane, "#{window_name}"}
}

// WindowPaneCount counts the panes sharing pane's window.
func (tmuxImpl) WindowPaneCount(pane string) (int, bool) {
	out, err := exec.Command("tmux", windowPanesArgs(pane)...).Output()
	if err != nil {
		return 0, false
	}
	return countLines(string(out)), true
}

func windowPanesArgs(pane string) []string {
	return []string{"list-panes", "-t", pane, "-F", "#{pane_id}"}
}

// countLines counts the non-empty lines of a tmux -F listing. Blank lines are
// skipped rather than counted, so the trailing newline does not inflate the
// count into a second pane that is not there -- which for the rename guard
// would be the expensive direction to be wrong in (it would silently stop
// renaming every window).
func countLines(out string) int {
	n := 0
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) != "" {
			n++
		}
	}
	return n
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

// maxPaneWalk bounds how far up the process tree FindPane looks. A claude
// process sits a handful of levels below its pane (pane shell -> wrappers ->
// node), so the limit is generous; it is here to keep a cycle or a mis-reported
// parent from spinning, not to reject legitimate depth.
const maxPaneWalk = 10

// FindPane locates the tmux pane pid belongs to, across every session on the
// server (-a), not just the client's own.
func (tmuxImpl) FindPane(pid int) (string, bool) {
	panes, err := listPanes()
	if err != nil {
		return "", false
	}
	return findPane(pid, panes, parentPID)
}

// findPane is the walk itself, taking the pane table and the parent lookup as
// arguments so it can be tested with neither tmux nor ps running.
//
// Bailing out at pid <= 1 rather than at 0 alone matters: reaching init means the
// walk left the pane's subtree, and pid 1's parent is itself on some systems.
func findPane(pid int, panes map[int]string, parent func(int) (int, bool)) (string, bool) {
	for depth := 0; depth < maxPaneWalk; depth++ {
		if pid <= 1 {
			return "", false
		}
		if pane, ok := panes[pid]; ok {
			return pane, true
		}
		next, ok := parent(pid)
		if !ok {
			return "", false
		}
		pid = next
	}
	return "", false
}

// PaneExists reports whether target is listed by the current server, across
// every session on it (-a). The ledger's pane column is not authoritative -- a
// recorded pane can belong to a tmux server that has since been replaced -- so
// the picker checks a pane before trusting it rather than switching blind and
// reading the failure as "the session died".
func (tmuxImpl) PaneExists(target string) bool {
	panes, err := listPanes()
	if err != nil {
		return false
	}
	return paneListed(panes, target)
}

// paneListed is the membership test, over the same pid -> pane map listPanes
// already builds, so no second tmux call is needed. Taking the map as an
// argument keeps it testable without a tmux server.
func paneListed(panes map[int]string, target string) bool {
	if target == "" {
		return false
	}
	for _, pane := range panes {
		if pane == target {
			return true
		}
	}
	return false
}

// ServerPID returns the pid of the tmux server this process talks to.
func (tmuxImpl) ServerPID() (int, bool) {
	out, err := exec.Command("tmux", "display", "-p", "#{pid}").Output()
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil || pid <= 0 {
		return 0, false
	}
	return pid, true
}

// listPanes maps each pane's pid to its pane id for the whole server.
func listPanes() (map[int]string, error) {
	out, err := exec.Command("tmux", "list-panes", "-a", "-F", "#{pane_pid} #{pane_id}").Output()
	if err != nil {
		return nil, err
	}
	return parsePanes(string(out)), nil
}

// parsePanes reads the "#{pane_pid} #{pane_id}" lines listPanes asks for.
// Unparseable lines are skipped rather than failed on: one odd pane must not
// cost the caller the rest of the table.
func parsePanes(out string) map[int]string {
	panes := map[int]string{}
	for _, line := range strings.Split(out, "\n") {
		pidStr, paneID, ok := strings.Cut(strings.TrimSpace(line), " ")
		if !ok {
			continue
		}
		pid, err := strconv.Atoi(pidStr)
		if err != nil {
			continue
		}
		panes[pid] = paneID
	}
	return panes
}

// parentPID returns pid's parent. This asks ps instead of reading /proc so the
// walk also works where /proc does not exist (macOS); the cost is a subprocess
// per level, which the maxPaneWalk bound keeps small.
func parentPID(pid int) (int, bool) {
	out, err := exec.Command("ps", "-o", "ppid=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0, false
	}
	ppid, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		return 0, false
	}
	return ppid, true
}
