package picker

import (
	"os/exec"
	"path/filepath"
	"strings"
)

// worktreeName returns the name of the git worktree directory containing cwd.
//
// A recorded cwd is not necessarily a worktree root: sessions are routinely
// started in a subdirectory, so filepath.Base(cwd) alone shows "claude-queue"
// where the worktree is "dotrc_queue-picker-worktree-session". A worktree's git
// toplevel is the worktree directory itself, which is the unit both the picker
// column and the tmux session name are after.
//
// The name is returned raw -- the on-disk directory name is what the column
// should show. Escaping for a multiplexer target (tmux's "." / ":" rewrite,
// e.g.) is that multiplexer implementation's own job, applied only where a
// target is actually built; this package stays multiplexer-agnostic per the
// Multiplexer abstraction (see internal/multiplexer's doc comment).
func worktreeName(cwd string) string {
	if cwd == "" {
		return ""
	}
	// A non-repo cwd (or no git at all) is not an error worth reporting: the
	// cwd's own basename is still the best name available.
	toplevel, err := exec.Command("git", "-C", cwd, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		toplevel = nil
	}
	return worktreeNameFrom(cwd, string(toplevel))
}

// worktreeNameFrom picks the name given a cwd and the git toplevel resolved
// for it, if any. Split from worktreeName so the fallback rule is testable
// without a git repository.
func worktreeNameFrom(cwd, toplevel string) string {
	if t := strings.TrimSpace(toplevel); t != "" {
		return dirName(t)
	}
	return dirName(cwd)
}

// dirName is filepath.Base with the degenerate results ("." for an empty path,
// "/" for the root) flattened to "", since neither names a worktree.
func dirName(path string) string {
	if path == "" {
		return ""
	}
	base := filepath.Base(path)
	if base == "." || base == string(filepath.Separator) {
		return ""
	}
	return base
}

// worktreeCache memoizes worktreeName per cwd. One name is resolved per picker
// row, and rows cluster onto a handful of worktrees (several sessions per
// repo), so this collapses tens of git invocations into one per distinct cwd.
type worktreeCache map[string]string

func (c worktreeCache) name(cwd string) string {
	if n, ok := c[cwd]; ok {
		return n
	}
	n := worktreeName(cwd)
	c[cwd] = n
	return n
}
