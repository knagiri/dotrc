package picker

import (
	"os/exec"
	"path/filepath"
	"strings"
)

// worktreeName returns the canonical tmux session name for the worktree that
// contains cwd: "<main-repo-basename>_<worktree-dir-name>" for a linked
// worktree, and just "<repo-basename>" for that repo's main checkout.
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
// fallbacks and the main-checkout case -- is testable without a repository.
func worktreeNameFrom(cwd, toplevel, commonDir string) string {
	top := strings.TrimSpace(toplevel)
	if top == "" {
		return dirName(cwd)
	}
	common := strings.TrimSpace(commonDir)
	if common == "" {
		return dirName(top)
	}
	mainTop := filepath.Dir(common) // parent of "<repo>/.git"
	if filepath.Clean(mainTop) == filepath.Clean(top) {
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
