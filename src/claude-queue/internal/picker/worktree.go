package picker

import (
	"os/exec"
	"path/filepath"
	"strings"
)

// worktreeName returns the canonical tmux session name for the worktree that
// contains cwd: "<main-repo-basename>_<worktree-dir-name>" for a linked
// worktree under <main-repo>/.worktrees/, and just "<dir-basename>" for that
// repo's main checkout or for a linked worktree that sits anywhere else.
//
// A recorded cwd is not necessarily a worktree root: sessions are routinely
// started in a subdirectory, so filepath.Base(cwd) alone shows "claude-queue"
// where the worktree is "foo". Two git facts pin the real name.
// --show-toplevel is the working tree's own root. --git-common-dir (absolute)
// is "<repo>/.git" for EVERY working tree of a repo -- the main checkout and
// all its linked worktrees alike -- so its parent is the main repo's toplevel
// in every case. When that parent equals the working tree's own toplevel, cwd
// is the main checkout and no "_<name>" suffix is added; the picker column and
// the tmux session then read just "<repo>".
//
// The "<repo>_<name>" composition is deliberately restricted to worktrees
// directly under "<main-repo>/.worktrees/", the layout bin/claude-worktree
// creates -- there it reproduces that script's own session name exactly
// (session="$(basename "$main_top")_${name}", and the worktree dir basename is
// that same <name>). Every other linked worktree keeps its own dir basename.
// Composing unconditionally would rename the worktrees of the legacy sibling
// layout ("<parent>/dotrc_foo", still on disk from before this repo moved to
// the subdirectory layout) to "dotrc_dotrc_foo", and since OpenSession creates
// a session when has-session misses, that spawns a SECOND tmux session
// alongside the existing "dotrc_foo" one -- breaking the 1 worktree = 1 session
// invariant the picker relies on. The basename fallback also matches a
// hand-made "git worktree add ../scratch".
//
// Both calls are best-effort: a non-repo cwd (or no git) falls back to the
// cwd's own basename, and a repo too old for --path-format=absolute (pre-2.31)
// falls back to the worktree dir basename -- the pre-canonicalization name.
//
// The name is returned raw -- the on-disk directory names are what the column
// should show. Escaping for a multiplexer target (tmux's "." / ":" rewrite,
// e.g.) is that multiplexer implementation's own job, applied only where a
// target is actually built; this package stays multiplexer-agnostic per the
// Multiplexer abstraction (see internal/multiplexer's doc comment).
func worktreeName(cwd string) string {
	if cwd == "" {
		return ""
	}
	toplevel, err := exec.Command("git", "-C", cwd, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		toplevel = nil
	}
	commonDir, err := exec.Command("git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir").Output()
	if err != nil {
		commonDir = nil
	}
	return worktreeNameFrom(cwd, string(toplevel), string(commonDir))
}

// worktreeNameFrom applies the naming rule to a cwd and the two git strings
// resolved for it. Split from worktreeName so the rule -- including both
// fallbacks, the main-checkout case and the .worktrees/-only composition -- is
// testable without a repository.
func worktreeNameFrom(cwd, toplevel, commonDir string) string {
	top := strings.TrimSpace(toplevel)
	if top == "" {
		return dirName(cwd)
	}
	common := strings.TrimSpace(commonDir)
	if common == "" {
		return dirName(top)
	}
	mainTop := filepath.Clean(filepath.Dir(common)) // parent of "<repo>/.git"
	if mainTop == filepath.Clean(top) {
		return dirName(top) // the main checkout: no worktree half to append
	}
	// Compose only for "<mainTop>/.worktrees/<name>"; see worktreeName's doc
	// comment for why every other linked worktree keeps its bare basename.
	if filepath.Dir(filepath.Clean(top)) != filepath.Join(mainTop, ".worktrees") {
		return dirName(top)
	}
	return dirName(mainTop) + "_" + dirName(top)
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
