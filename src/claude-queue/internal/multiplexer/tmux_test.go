package multiplexer

import (
	"slices"
	"strings"
	"testing"
)

// wantCommand is what `claude attach abc` must reach tmux as: one shell
// command, so the pane survives the command and drops back to a shell, having
// first released the window name that -S dedupes on.
const wantCommand = `'claude' 'attach' 'abc'; tmux rename-window -t "$TMUX_PANE" 'claude-attach-abc~exited'; exec "${SHELL:-/bin/bash}"`

// The argv builders are exercised instead of OpenSession itself so the contract
// is checked without starting a real tmux server.
func TestNewSessionArgs(t *testing.T) {
	tests := []struct {
		name   string
		sess   string
		window string
		cwd    string
		argv   []string
		want   []string
	}{
		{
			name:   "with cwd",
			sess:   "dotrc_wt",
			window: "claude-attach-abc",
			cwd:    "/w/a",
			argv:   []string{"claude", "attach", "abc"},
			want:   []string{"new-session", "-d", "-s", "dotrc_wt", "-n", "claude-attach-abc", "-c", "/w/a", wantCommand},
		},
		{
			name:   "without cwd",
			sess:   "dotrc_wt",
			window: "claude-attach-abc",
			cwd:    "",
			argv:   []string{"claude", "attach", "abc"},
			want:   []string{"new-session", "-d", "-s", "dotrc_wt", "-n", "claude-attach-abc", wantCommand},
		},
		{
			// No command leaves tmux to start its default shell, which is
			// where the wrapper would have landed anyway.
			name:   "empty argv adds no command",
			sess:   "dotrc_wt",
			window: "cmd",
			cwd:    "/w/a",
			argv:   nil,
			want:   []string{"new-session", "-d", "-s", "dotrc_wt", "-n", "cmd", "-c", "/w/a"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := newSessionArgs(tt.sess, tt.window, tt.cwd, tt.argv)
			if !slices.Equal(got, tt.want) {
				t.Errorf("newSessionArgs(%q, %q, %q, %v) = %v, want %v", tt.sess, tt.window, tt.cwd, tt.argv, got, tt.want)
			}
			// Creating the session detached is mandatory: the picker runs in
			// a display-popup, and an attaching new-session would fight it
			// for the terminal. switch-client moves the client afterwards.
			if !slices.Contains(got, "-d") {
				t.Errorf("newSessionArgs(...) = %v, must contain -d", got)
			}
		})
	}
}

// TestNewSessionArgsWindowNameMatchesNewWindow pins the regression this fix
// addresses: the window newSessionArgs creates (via -n) must be named exactly
// what newWindowArgs' -S will later look for. If these two ever diverge, a
// second OpenSession pick of the same target stacks a second window instead
// of -S selecting the first one -- the idempotency newWindowArgs documents
// would only hold when the session already existed, never on first creation.
func TestNewSessionArgsWindowNameMatchesNewWindow(t *testing.T) {
	argv := []string{"claude", "attach", "abc"}
	window := "claude-attach-abc"

	sessionArgs := newSessionArgs("dotrc_wt", window, "/w/a", argv)
	windowArgs := newWindowArgs("dotrc_wt", window, "/w/a", argv)

	sessionWindowName := sessionArgs[slices.Index(sessionArgs, "-n")+1]
	targetWindowName := windowArgs[slices.Index(windowArgs, "-n")+1]

	if sessionWindowName != targetWindowName {
		t.Errorf("newSessionArgs names the initial window %q, but newWindowArgs' -S looks for %q; a second pick would stack a new window instead of reusing it", sessionWindowName, targetWindowName)
	}
}

func TestNewWindowArgs(t *testing.T) {
	tests := []struct {
		name   string
		sess   string
		window string
		cwd    string
		argv   []string
		want   []string
	}{
		{
			name:   "with cwd",
			sess:   "dotrc",
			window: "claude-attach-abc",
			cwd:    "/w/a",
			argv:   []string{"claude", "attach", "abc"},
			want: []string{
				"new-window", "-S", "-n", "claude-attach-abc", "-t", "=dotrc:",
				"-c", "/w/a", wantCommand,
			},
		},
		{
			name:   "without cwd",
			sess:   "dotrc",
			window: "claude-attach-abc",
			cwd:    "",
			argv:   []string{"claude", "attach", "abc"},
			want: []string{
				"new-window", "-S", "-n", "claude-attach-abc", "-t", "=dotrc:",
				wantCommand,
			},
		},
		{
			name:   "empty argv adds no command",
			sess:   "dotrc",
			window: "cmd",
			cwd:    "",
			argv:   nil,
			want: []string{
				"new-window", "-S", "-n", "cmd", "-t", "=dotrc:",
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := newWindowArgs(tt.sess, tt.window, tt.cwd, tt.argv)
			if !slices.Equal(got, tt.want) {
				t.Errorf("newWindowArgs(...) = %v, want %v", got, tt.want)
			}
			// The picker opens a window to move the user there; -d would
			// leave the new window in the background and make the pick
			// look like a no-op.
			if slices.Contains(got, "-d") {
				t.Errorf("newWindowArgs(...) = %v, must not contain -d", got)
			}
			// Without the "=" prefix tmux falls back to prefix/glob matching,
			// so "dotrc" could land in "dotrc_queue-picker-worktree-session".
			target := got[slices.Index(got, "-t")+1]
			if !strings.HasPrefix(target, "=") {
				t.Errorf("target = %q, must be anchored with a leading =", target)
			}
			// The trailing ":" leaves the window name empty, which is what
			// asks tmux for the next unused index.
			if !strings.HasSuffix(target, ":") {
				t.Errorf("target = %q, must end with : to take the next free index", target)
			}
		})
	}
}

func TestShellQuote(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "ordinary word",
			in:   "claude",
			want: `'claude'`,
		},
		{
			// Unquoted this would become two words and run the wrong command.
			name: "spaces stay one word",
			in:   "/w/my worktree",
			want: `'/w/my worktree'`,
		},
		{
			// The one character single quotes cannot escape: the run is
			// closed, an escaped quote spliced in, and a new run opened.
			name: "single quote is spliced",
			in:   "it's",
			want: `'it'\''s'`,
		},
		{
			// $ and ` are inert inside single quotes, so they need no
			// treatment of their own -- which is the reason for this form.
			name: "expansions are inert",
			in:   "$(rm -rf /)`x`",
			want: "'$(rm -rf /)`x`'",
		},
		{
			// A newline is an ordinary character inside single quotes, so it
			// stays part of the word instead of ending the command.
			name: "newline stays inside the word",
			in:   "a\nb",
			want: "'a\nb'",
		},
		{
			name: "empty stays a word",
			in:   "",
			want: `''`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shellQuote(tt.in); got != tt.want {
				t.Errorf("shellQuote(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestWindowCommand(t *testing.T) {
	t.Run("one argument, ending in an exec of the shell", func(t *testing.T) {
		got := windowCommand("claude-attach-abc", []string{"claude", "attach", "abc"})
		// A single argument is what makes tmux run the string through a
		// shell; more than one would be exec'd directly and the exec tail
		// would be read as a literal argument to claude.
		if len(got) != 1 {
			t.Fatalf("windowCommand(...) = %v, want exactly one argument", got)
		}
		if got[0] != wantCommand {
			t.Errorf("windowCommand(...) = %q, want %q", got[0], wantCommand)
		}
	})

	t.Run("every element is quoted", func(t *testing.T) {
		got := windowCommand("w", []string{"claude", "--resume", "a b'c"})
		want := `'claude' '--resume' 'a b'\''c'; tmux rename-window -t "$TMUX_PANE" 'w~exited'; exec "${SHELL:-/bin/bash}"`
		if len(got) != 1 || got[0] != want {
			t.Errorf("windowCommand(...) = %v, want [%q]", got, want)
		}
	})

	t.Run("empty argv yields no argument", func(t *testing.T) {
		if got := windowCommand("cmd", nil); len(got) != 0 {
			t.Errorf("windowCommand(%q, nil) = %v, want no argument so tmux starts its default shell", "cmd", got)
		}
	})
}

// TestWindowCommandReleasesTheDedupeName pins the repair for the regression the
// shell wrap would otherwise introduce. -S selects an existing window of the
// same name *instead of* running the command, so once the window outlives the
// command, a second pick of the same target would drop the user into the
// leftover shell and never re-run claude. The command therefore has to rename
// the window out of the way before it execs the shell, and the name it releases
// must be exactly the one -S looks for.
func TestWindowCommandReleasesTheDedupeName(t *testing.T) {
	argv := []string{"claude", "attach", "abc"}
	window := "claude-attach-abc"

	for _, tt := range []struct {
		name string
		args []string
	}{
		{"new-session", newSessionArgs("dotrc_wt", window, "/w/a", argv)},
		{"new-window", newWindowArgs("dotrc_wt", window, "/w/a", argv)},
	} {
		t.Run(tt.name, func(t *testing.T) {
			named := tt.args[slices.Index(tt.args, "-n")+1]
			command := tt.args[len(tt.args)-1]

			wantRename := `tmux rename-window -t "$TMUX_PANE" ` + shellQuote(named+exitedSuffix)
			if !strings.Contains(command, wantRename) {
				t.Errorf("command = %q, must release the -n name %q via %q", command, named, wantRename)
			}
			// The rename has to happen before the exec, or the shell replaces
			// the process and the rename never runs.
			if strings.Index(command, wantRename) > strings.Index(command, "exec") {
				t.Errorf("command = %q, renames after exec; the exec never returns so the rename would be dead", command)
			}
		})
	}

	// A released name must not be picked up by a later -S. sanitizeWindowName
	// strips "~", so no caller-supplied name -- not even one that already ends
	// in the suffix -- can reach tmux still carrying it.
	for _, probe := range []string{"claude-attach-abc", "u~exited", "a.b:c", "~exited"} {
		if strings.HasSuffix(sanitizeWindowName(probe), exitedSuffix) {
			t.Errorf("sanitizeWindowName(%q) = %q ends with %q; a live window could collide with a released one", probe, sanitizeWindowName(probe), exitedSuffix)
		}
	}
}

// TestWindowCommandUsesTheGivenName pins that the name the window is created
// under and the name its exit rename releases are the same string the caller
// handed in. The wrap around the command must not leak into either: if the
// two ever diverge, -S stops matching and repeat picks stack windows.
func TestWindowCommandUsesTheGivenName(t *testing.T) {
	const window = "AWS-ログ調査-6773febd"

	got := windowCommand(window, []string{"claude", "attach", "abc"})
	if len(got) != 1 {
		t.Fatalf("windowCommand(...) = %v, want exactly one argument", got)
	}
	if !strings.Contains(got[0], shellQuote(window+exitedSuffix)) {
		t.Errorf("windowCommand(...) = %q, must release exactly %q", got[0], window+exitedSuffix)
	}
	// The caller's name is what -n installs, unchanged.
	args := newWindowArgs("dotrc_wt", window, "/w/a", []string{"claude", "attach", "abc"})
	if named := args[slices.Index(args, "-n")+1]; named != window {
		t.Errorf("newWindowArgs named the window %q, want the caller's %q", named, window)
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

func TestSanitizeWindowName(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{
			// The common case: internal/label already produced a tmux-safe
			// name, so this must be a pass-through -- including the Japanese
			// most titles are written in.
			name: "an already-safe label is untouched",
			in:   "ロググループの管理-0837e774",
			want: "ロググループの管理-0837e774",
		},
		{
			// "." and ":" are the window.pane and session:window separators
			// in tmux -t targets, so they cannot survive in a window name.
			name: "separators are replaced",
			in:   "a.b:c",
			want: "a-b-c",
		},
		{
			// "~" belongs to exitedSuffix; a name carrying it could collide
			// with a released one and swallow the next pick.
			name: "tilde is replaced",
			in:   "u~exited",
			want: "u-exited",
		},
		{
			// tmux would read a leading "-" as an option to rename-window.
			name: "edge dashes are trimmed",
			in:   "-mid-dle-",
			want: "mid-dle",
		},
		{
			name: "empty falls back",
			in:   "",
			want: "cmd",
		},
		{
			name: "all-separator input falls back",
			in:   "...",
			want: "cmd",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := sanitizeWindowName(tt.in); got != tt.want {
				t.Errorf("sanitizeWindowName(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

// sanitizeWindowName is a backstop, not the formatter: internal/label owns the
// width budget, and a second truncation here under a different rule would make
// -n, -S and the exit rename disagree about the same window.
func TestSanitizeWindowNameDoesNotTruncate(t *testing.T) {
	long := strings.Repeat("a", 200)
	if got := sanitizeWindowName(long); got != long {
		t.Errorf("sanitizeWindowName truncated a %d-char name to %d chars", len(long), len(got))
	}
}

// findPane is exercised through its injected lookups so the walk is asserted
// without a tmux server or a real process tree.
func TestFindPane(t *testing.T) {
	panes := map[int]string{100: "%3", 200: "%7"}

	// chain models `ps -o ppid=`: 104 -> 103 -> 102 -> 100 (a pane pid).
	chain := map[int]int{104: 103, 103: 102, 102: 100, 300: 1}
	parent := func(pid int) (int, bool) {
		ppid, ok := chain[pid]
		return ppid, ok
	}

	t.Run("the pane pid itself matches", func(t *testing.T) {
		got, ok := findPane(200, panes, parent)
		if !ok || got != "%7" {
			t.Errorf("findPane(200) = (%q, %v), want (%%7, true)", got, ok)
		}
	})

	t.Run("a descendant matches via its ancestor", func(t *testing.T) {
		// This is the case the picker depends on: the claude process is several
		// levels below the shell tmux recorded as the pane's pid.
		got, ok := findPane(104, panes, parent)
		if !ok || got != "%3" {
			t.Errorf("findPane(104) = (%q, %v), want (%%3, true)", got, ok)
		}
	})

	t.Run("no pane in the ancestry", func(t *testing.T) {
		// Walking out to init means the process is not under any pane.
		if got, ok := findPane(300, panes, parent); ok {
			t.Errorf("findPane(300) = (%q, true), want not found", got)
		}
	})

	t.Run("an unknown parent stops the walk", func(t *testing.T) {
		if got, ok := findPane(999, panes, parent); ok {
			t.Errorf("findPane(999) = (%q, true), want not found", got)
		}
	})

	t.Run("pid at or below init is never searched", func(t *testing.T) {
		for _, pid := range []int{1, 0, -1} {
			if got, ok := findPane(pid, map[int]string{1: "%1", 0: "%0"}, parent); ok {
				t.Errorf("findPane(%d) = (%q, true), want not found", pid, got)
			}
		}
	})

	t.Run("the depth limit cuts a long chain off", func(t *testing.T) {
		// A parent chain that only reaches the pane beyond maxPaneWalk must be
		// abandoned rather than followed forever.
		deep := func(pid int) (int, bool) { return pid + 1, true }
		if got, ok := findPane(1000, map[int]string{1000 + maxPaneWalk: "%9"}, deep); ok {
			t.Errorf("findPane past the depth limit = (%q, true), want not found", got)
		}
		// One step inside the limit still resolves, which is what shows the
		// cutoff above is the limit and not an off-by-one that never matches.
		if got, ok := findPane(1000, map[int]string{1000 + maxPaneWalk - 1: "%9"}, deep); !ok || got != "%9" {
			t.Errorf("findPane at the last allowed depth = (%q, %v), want (%%9, true)", got, ok)
		}
	})
}

func TestParsePanes(t *testing.T) {
	// Real `tmux list-panes -a -F "#{pane_pid} #{pane_id}"` output, plus the
	// trailing newline it always ends with.
	got := parsePanes("2249851 %0\n198617 %12\n")
	want := map[int]string{2249851: "%0", 198617: "%12"}
	if len(got) != len(want) {
		t.Fatalf("parsePanes = %v, want %v", got, want)
	}
	for pid, pane := range want {
		if got[pid] != pane {
			t.Errorf("parsePanes[%d] = %q, want %q", pid, got[pid], pane)
		}
	}

	// Lines tmux would never emit must be skipped, not turned into a 0 pid that
	// the walk could then match against.
	if got := parsePanes("junk\n\nnotapid %1\n42 %2\n"); len(got) != 1 || got[42] != "%2" {
		t.Errorf("parsePanes with junk lines = %v, want only 42:%%2", got)
	}
}

// The window-naming commands are asserted as argv, for the same reason the
// session builders are: the contract is the argument list, and checking it
// needs no tmux server.
func TestWindowNamingArgs(t *testing.T) {
	// A pane id where tmux documents a target-window is deliberate: tmux
	// resolves it to the window holding the pane, which is the only handle a
	// hook has ($TMUX_PANE).
	if got, want := renameWindowArgs("%5", "topic-6773febd"),
		[]string{"rename-window", "-t", "%5", "topic-6773febd"}; !slices.Equal(got, want) {
		t.Errorf("renameWindowArgs = %v, want %v", got, want)
	}
	if got, want := automaticRenameArgs("%5", true),
		[]string{"setw", "-t", "%5", "automatic-rename", "on"}; !slices.Equal(got, want) {
		t.Errorf("automaticRenameArgs(on) = %v, want %v", got, want)
	}
	if got, want := automaticRenameArgs("%5", false),
		[]string{"setw", "-t", "%5", "automatic-rename", "off"}; !slices.Equal(got, want) {
		t.Errorf("automaticRenameArgs(off) = %v, want %v", got, want)
	}
	if got, want := windowNameArgs("%5"),
		[]string{"display", "-p", "-t", "%5", "#{window_name}"}; !slices.Equal(got, want) {
		t.Errorf("windowNameArgs = %v, want %v", got, want)
	}
	// -F over the window's panes: the count is the number of lines, so the
	// format has to be one field per pane and nothing else.
	if got, want := windowPanesArgs("%5"),
		[]string{"list-panes", "-t", "%5", "-F", "#{pane_id}"}; !slices.Equal(got, want) {
		t.Errorf("windowPanesArgs = %v, want %v", got, want)
	}
}

func TestCountLines(t *testing.T) {
	tests := []struct {
		name string
		out  string
		want int
	}{
		{
			// The single-pane answer is what the hook's rename guard turns on,
			// and tmux always ends its listing with a newline: counting that
			// as a second pane would stop every rename.
			name: "one pane with a trailing newline",
			out:  "%5\n",
			want: 1,
		},
		{
			name: "a split window",
			out:  "%5\n%6\n",
			want: 2,
		},
		{
			name: "no output at all",
			out:  "",
			want: 0,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := countLines(tt.out); got != tt.want {
				t.Errorf("countLines(%q) = %d, want %d", tt.out, got, tt.want)
			}
		})
	}
}
