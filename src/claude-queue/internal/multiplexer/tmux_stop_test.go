package multiplexer

import (
	"slices"
	"testing"
)

// With -S and -d together tmux does nothing when a window of the same name
// exists, so the delivery would "succeed" without starting claude. The
// detached open for an existing session must therefore never carry -S.
func TestDetachedOpenArgs_ExistingSessionHasNoS(t *testing.T) {
	got := DetachedOpenArgs("s", "w", "/c", nil, []string{"claude"}, true)
	if got[0] != "new-window" || got[1] != "-d" {
		t.Errorf("got %v, want new-window -d ...", got)
	}
	if slices.Contains(got, "-S") {
		t.Errorf("got %v, must not contain -S", got)
	}
	if !slices.Contains(got, "-n") || !slices.Contains(got, "=s:") {
		t.Errorf("got %v lost the window name or target", got)
	}
}
