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
	window := windowName(argv)

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
	window := windowName(argv)

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

	// A released name must not be picked up by a later -S. windowName keeps
	// only [A-Za-z0-9_-], so no argv -- not even one containing "~" itself --
	// can produce a name that ends in the suffix.
	for _, probe := range [][]string{argv, {"claude", "--resume", "u~exited"}, {"a.b", "c:d"}} {
		if strings.HasSuffix(windowName(probe), exitedSuffix) {
			t.Errorf("windowName(%v) = %q ends with %q; a live window could collide with a released one", probe, windowName(probe), exitedSuffix)
		}
	}
}

// TestWindowNameIgnoresShellWrap pins that the dedupe key stays derived from
// the raw argv. Computing it from the wrapped command instead would fold the
// "; exec ..." tail into every window name, changing what newWindowArgs' -S
// matches on -- and the names of the two paths would drift apart the moment
// only one of them wrapped.
func TestWindowNameIgnoresShellWrap(t *testing.T) {
	argv := []string{"claude", "attach", "abc"}

	if got, want := windowName(argv), "claude-attach-abc"; got != want {
		t.Errorf("windowName(%v) = %q, want %q", argv, got, want)
	}
	if wrapped := windowName(windowCommand(windowName(argv), argv)); wrapped == windowName(argv) {
		t.Errorf("windowName of the wrapped command = %q, expected it to differ from the raw-argv name; the wrap must not feed windowName", wrapped)
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

func TestWindowName(t *testing.T) {
	tests := []struct {
		name string
		argv []string
		want string
	}{
		{
			name: "claude attach",
			argv: []string{"claude", "attach", "61c846eb"},
			want: "claude-attach-61c846eb",
		},
		{
			// "." and ":" are the window.pane and session:window separators
			// in tmux -t targets, so they cannot survive in a window name.
			name: "separators are replaced",
			argv: []string{"a.b", "c:d"},
			want: "a_b-c_d",
		},
		{
			name: "empty argv",
			argv: nil,
			want: "cmd",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := windowName(tt.argv); got != tt.want {
				t.Errorf("windowName(%v) = %q, want %q", tt.argv, got, tt.want)
			}
		})
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
