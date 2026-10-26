package multiplexer

import (
	"slices"
	"testing"
)

// A session created from the watch pass would get the service's environment
// through update-environment, so the detached open only ever adds a window.
func TestDetachedOpenArgs_NeverCreatesSession(t *testing.T) {
	got := DetachedOpenArgs("s", "w", "/c", map[string]string{"K": "v"}, []string{"claude"})
	if slices.Contains(got, "new-session") || got[0] != "new-window" {
		t.Errorf("got %v, want a new-window and no new-session", got)
	}
}

func TestLastAttached(t *testing.T) {
	for _, tc := range []struct{ out, want string }{
		{"1700000300 work\n1700000900 main\n1700000100 other\n", "main"},
		// Never attached prints an empty time and loses to any attach.
		{" fresh\n1700000000 used\n", "used"},
		{" fresh\n", "fresh"},
		// A session name may hold spaces; only the first one separates.
		{"5 my session\n3 b\n", "my session"},
	} {
		got, err := lastAttached(tc.out)
		if err != nil || got != tc.want {
			t.Errorf("lastAttached(%q) = %q, %v; want %q", tc.out, got, err, tc.want)
		}
	}
	if _, err := lastAttached(""); err == nil {
		t.Error("no session: want an error")
	}
}

// With -S and -d together tmux does nothing when a window of the same name
// exists, so the delivery would "succeed" without starting claude. The
// detached open for an existing session must therefore never carry -S.
func TestDetachedOpenArgs_ExistingSessionHasNoS(t *testing.T) {
	got := DetachedOpenArgs("s", "w", "/c", nil, []string{"claude"})
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
