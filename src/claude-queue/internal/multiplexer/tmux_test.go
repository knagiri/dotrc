package multiplexer

import (
	"slices"
	"strings"
	"testing"
)

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
			want:   []string{"new-session", "-d", "-s", "dotrc_wt", "-n", "claude-attach-abc", "-c", "/w/a", "claude", "attach", "abc"},
		},
		{
			name:   "without cwd",
			sess:   "dotrc_wt",
			window: "claude-attach-abc",
			cwd:    "",
			argv:   []string{"claude", "attach", "abc"},
			want:   []string{"new-session", "-d", "-s", "dotrc_wt", "-n", "claude-attach-abc", "claude", "attach", "abc"},
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
				"-c", "/w/a", "claude", "attach", "abc",
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
				"claude", "attach", "abc",
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
