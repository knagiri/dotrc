package picker

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The git call and the naming rule are split so this table can pin the rule --
// including the fallback -- without a repository on disk.
func TestWorktreeNameFrom(t *testing.T) {
	tests := []struct {
		name     string
		cwd      string
		toplevel string
		want     string
	}{
		{
			// The case this whole derivation exists for: a session started
			// well below the worktree root still names the worktree.
			name:     "deep subdirectory resolves to the worktree",
			cwd:      "/home/x/ghq/github.com/knagiri/dotrc_wt/src/claude-queue",
			toplevel: "/home/x/ghq/github.com/knagiri/dotrc_wt\n",
			want:     "dotrc_wt",
		},
		{
			name:     "cwd already at the worktree root",
			cwd:      "/home/x/ghq/github.com/knagiri/dotrc_wt",
			toplevel: "/home/x/ghq/github.com/knagiri/dotrc_wt\n",
			want:     "dotrc_wt",
		},
		{
			// git failed (not a repo, or git missing): the cwd's own basename
			// is still the best name available.
			name:     "no toplevel falls back to the cwd basename",
			cwd:      "/home/x/scratch/notes",
			toplevel: "",
			want:     "notes",
		},
		{
			name:     "blank toplevel is treated as no toplevel",
			cwd:      "/home/x/scratch/notes",
			toplevel: "  \n",
			want:     "notes",
		},
		{
			// No cwd recorded: there is no worktree to name, and "" is what
			// makes the attach path print its manual fallback instead of
			// building a nonsense tmux target.
			name:     "empty cwd yields no name",
			cwd:      "",
			toplevel: "",
			want:     "",
		},
		{
			name:     "root cwd yields no name",
			cwd:      "/",
			toplevel: "",
			want:     "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := worktreeNameFrom(tt.cwd, tt.toplevel); got != tt.want {
				t.Errorf("worktreeNameFrom(%q, %q) = %q, want %q", tt.cwd, tt.toplevel, got, tt.want)
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

func TestSanitizeSessionName(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "already valid",
			in:   "dotrc_queue-picker-worktree-session",
			want: "dotrc_queue-picker-worktree-session",
		},
		{
			// tmux reads "." as the window.pane separator in -t targets, and
			// silently stores the session under the substituted name anyway.
			name: "dot becomes underscore",
			in:   "eversteel.api",
			want: "eversteel_api",
		},
		{
			// ":" is the session:window separator.
			name: "colon becomes underscore",
			in:   "repo:branch",
			want: "repo_branch",
		},
		{
			name: "empty stays empty",
			in:   "",
			want: "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := sanitizeSessionName(tt.in); got != tt.want {
				t.Errorf("sanitizeSessionName(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
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
