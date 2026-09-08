package picker

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The git calls and the naming rule are split so this table can pin the rule --
// including both fallbacks and the main-checkout case -- without a repository
// on disk.
func TestWorktreeNameFrom(t *testing.T) {
	tests := []struct {
		name      string
		cwd       string
		toplevel  string
		commonDir string
		want      string
	}{
		{
			// The case this whole derivation exists for: a session started
			// well below the worktree root still names the worktree -- and
			// the name carries the repo it belongs to.
			name:      "linked worktree, deep subdirectory",
			cwd:       "/home/x/ghq/github.com/knagiri/dotrc/.worktrees/foo/src/claude-queue",
			toplevel:  "/home/x/ghq/github.com/knagiri/dotrc/.worktrees/foo\n",
			commonDir: "/home/x/ghq/github.com/knagiri/dotrc/.git\n",
			want:      "dotrc_foo",
		},
		{
			name:      "linked worktree, cwd at worktree root",
			cwd:       "/home/x/ghq/github.com/knagiri/dotrc/.worktrees/foo",
			toplevel:  "/home/x/ghq/github.com/knagiri/dotrc/.worktrees/foo\n",
			commonDir: "/home/x/ghq/github.com/knagiri/dotrc/.git\n",
			want:      "dotrc_foo",
		},
		{
			// The main checkout's own toplevel is the parent of the common
			// dir, so there is no worktree half to append.
			name:      "main checkout: toplevel == parent of common-dir, no suffix",
			cwd:       "/home/x/ghq/github.com/knagiri/dotrc",
			toplevel:  "/home/x/ghq/github.com/knagiri/dotrc\n",
			commonDir: "/home/x/ghq/github.com/knagiri/dotrc/.git\n",
			want:      "dotrc",
		},
		{
			// git failed (not a repo, or git missing): the cwd's own basename
			// is still the best name available.
			name:      "no toplevel falls back to the cwd basename",
			cwd:       "/home/x/scratch/notes",
			toplevel:  "",
			commonDir: "",
			want:      "notes",
		},
		{
			// A repo too old for --path-format=absolute (pre-2.31) resolves a
			// toplevel but no common dir; the pre-canonicalization name (the
			// worktree dir basename) is the right fallback.
			name:      "toplevel present but no common-dir: pre-canonicalization fallback",
			cwd:       "/home/x/ghq/github.com/knagiri/dotrc/.worktrees/foo",
			toplevel:  "/home/x/ghq/github.com/knagiri/dotrc/.worktrees/foo\n",
			commonDir: "",
			want:      "foo",
		},
		{
			name:      "blank toplevel is treated as no toplevel",
			cwd:       "/home/x/scratch/notes",
			toplevel:  "  \n",
			commonDir: "",
			want:      "notes",
		},
		{
			// No cwd recorded: there is no worktree to name, and "" is what
			// makes the attach path print its manual fallback instead of
			// building a nonsense tmux target.
			name:      "empty cwd yields no name",
			cwd:       "",
			toplevel:  "",
			commonDir: "",
			want:      "",
		},
		{
			name:      "root cwd yields no name",
			cwd:       "/",
			toplevel:  "",
			commonDir: "",
			want:      "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := worktreeNameFrom(tt.cwd, tt.toplevel, tt.commonDir); got != tt.want {
				t.Errorf("worktreeNameFrom(%q, %q, %q) = %q, want %q", tt.cwd, tt.toplevel, tt.commonDir, got, tt.want)
			}
		})
	}
}

// The end-to-end shape of the reported bug, against a real git worktree: the
// session's cwd is <worktree>/src/claude-queue and the name must still be the
// worktree directory, not "claude-queue".
func TestWorktreeName_DeepSubdirectoryOfRealRepo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	const wtName = "dotrc_queue-picker-worktree-session"
	root := filepath.Join(t.TempDir(), wtName)
	deep := filepath.Join(root, "src", "claude-queue")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("git", "-C", root, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v: %s", err, out)
	}

	if got := worktreeName(deep); got != wtName {
		t.Errorf("worktreeName(%q) = %q, want %q", deep, got, wtName)
	}
	if got := worktreeName(root); got != wtName {
		t.Errorf("worktreeName(%q) = %q, want %q", root, got, wtName)
	}
}

// A real linked worktree under <repo>/.worktrees/<name>: the name must compose
// the main repo basename with the worktree dir name, from any depth, while the
// main checkout of the same repo keeps its bare repo name.
func TestWorktreeName_LinkedWorktreeOfRealRepo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	base := t.TempDir()
	main := filepath.Join(base, "dotrc")
	if err := os.MkdirAll(main, 0o755); err != nil {
		t.Fatal(err)
	}
	run := func(args ...string) {
		t.Helper()
		full := append([]string{"-C", main}, args...)
		if out, err := exec.Command("git", full...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	run("init", "-q")
	run("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
	wt := filepath.Join(main, ".worktrees", "foo")
	run("worktree", "add", "-q", wt, "-b", "foo")

	deep := filepath.Join(wt, "src", "claude-queue")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := worktreeName(deep); got != "dotrc_foo" {
		t.Errorf("worktreeName(%q) = %q, want dotrc_foo", deep, got)
	}
	if got := worktreeName(wt); got != "dotrc_foo" {
		t.Errorf("worktreeName(%q) = %q, want dotrc_foo", wt, got)
	}
	if got := worktreeName(main); got != "dotrc" {
		t.Errorf("worktreeName(%q) = %q, want dotrc (main checkout, no suffix)", main, got)
	}
}

// A cached cwd must not re-run git: the picker resolves a name for every row
// and rows cluster onto a few worktrees. The sentinel would be impossible to
// derive from the path, so seeing it back proves the cache was consulted.
func TestWorktreeCache_ReusesResolvedName(t *testing.T) {
	c := worktreeCache{"/w/a": "sentinel"}
	if got := c.name("/w/a"); got != "sentinel" {
		t.Errorf("cached name = %q, want sentinel", got)
	}
	// A miss resolves and then memoizes, so a second lookup is served from
	// the map.
	if got := c.name(""); got != "" {
		t.Errorf("empty cwd name = %q, want empty", got)
	}
	if _, ok := c[""]; !ok {
		t.Error("resolved name was not memoized")
	}
}
