package picker

import (
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// repoKey identifies the repository a cwd belongs to by an id its main checkout
// and every one of its linked worktrees share: the absolute --git-common-dir,
// which is "<repo>/.git" for all of them. "" means cwd is not inside a git repo
// (or git is unavailable) -- the caller treats that as "cannot scope by repo".
func repoKey(cwd string) string {
	if cwd == "" {
		return ""
	}
	out, err := exec.Command("git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir").Output()
	if err != nil {
		return ""
	}
	key := strings.TrimSpace(string(out))
	if key == "" {
		return ""
	}
	return filepath.Clean(key)
}

// repoKeyCache memoizes repoKey per cwd. The picker resolves a key for every
// listed row and rows cluster onto a handful of worktrees, so this collapses
// tens of git invocations into one per distinct cwd (mirrors worktreeCache).
type repoKeyCache map[string]string

func (c repoKeyCache) key(cwd string) string {
	if k, ok := c[cwd]; ok {
		return k
	}
	k := repoKey(cwd)
	c[cwd] = k
	return k
}

// filterSameRepo keeps the rows whose cwd resolves to wantKey. keyOf is injected
// so the rule is testable without a filesystem; Run passes repoKeyCache{}.key.
func filterSameRepo(rows []db.Row, wantKey string, keyOf func(string) string) []db.Row {
	var out []db.Row
	for _, r := range rows {
		if keyOf(rowCwd(r)) == wantKey {
			out = append(out, r)
		}
	}
	return out
}
