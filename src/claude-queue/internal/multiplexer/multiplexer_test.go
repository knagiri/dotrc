package multiplexer

import "testing"

func TestDetect_TmuxEnv(t *testing.T) {
	t.Setenv("TMUX", "/tmp/tmux-1000/default,1234,0")
	t.Setenv("TMUX_PANE", "%42")
	m := Detect()
	if _, ok := m.(tmuxImpl); !ok {
		t.Fatalf("Detect: got %T, want tmuxImpl", m)
	}
	if got := m.PaneID(); got != "%42" {
		t.Errorf("PaneID = %q, want %q", got, "%42")
	}
}

func TestDetect_NoMultiplexer(t *testing.T) {
	t.Setenv("TMUX", "")
	m := Detect()
	if _, ok := m.(noopImpl); !ok {
		t.Fatalf("Detect: got %T, want noopImpl", m)
	}
	if got := m.PaneID(); got != "" {
		t.Errorf("PaneID = %q, want empty", got)
	}
	// noop methods must not panic.
	m.RefreshStatus()
	if err := m.Switch("anything"); err != nil {
		t.Errorf("noop Switch err = %v, want nil", err)
	}
	// Unlike Switch, NewWindow must return an error: the picker's attach path
	// relies on this to decide whether to print a manual-fallback hint.
	if err := m.NewWindow("/w/a", []string{"claude", "attach", "abc"}); err == nil {
		t.Errorf("noop NewWindow err = nil, want non-nil")
	}
}
