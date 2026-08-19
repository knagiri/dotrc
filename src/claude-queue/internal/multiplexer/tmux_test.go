package multiplexer

import (
	"slices"
	"testing"
)

// newWindowArgs is exercised instead of NewWindow itself so the argv contract
// is checked without starting a real tmux server.
func TestNewWindowArgs(t *testing.T) {
	tests := []struct {
		name string
		cwd  string
		argv []string
		want []string
	}{
		{
			name: "with cwd",
			cwd:  "/w/a",
			argv: []string{"claude", "attach", "abc"},
			want: []string{"new-window", "-c", "/w/a", "claude", "attach", "abc"},
		},
		{
			name: "without cwd",
			cwd:  "",
			argv: []string{"claude", "attach", "abc"},
			want: []string{"new-window", "claude", "attach", "abc"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := newWindowArgs(tt.cwd, tt.argv)
			if !slices.Equal(got, tt.want) {
				t.Errorf("newWindowArgs(%q, %v) = %v, want %v", tt.cwd, tt.argv, got, tt.want)
			}
			// The picker opens a window to move the user there; -d would
			// leave the new window in the background and make the pick
			// look like a no-op.
			if slices.Contains(got, "-d") {
				t.Errorf("newWindowArgs(%q, %v) = %v, must not contain -d", tt.cwd, tt.argv, got)
			}
		})
	}
}
