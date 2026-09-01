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
	// Unlike Switch, OpenSession must return an error: the picker's attach path
	// relies on this to decide whether to print a manual-fallback hint.
	if err := m.OpenSession("dotrc_wt", "/w/a", "some-window", []string{"claude", "attach", "abc"}); err == nil {
		t.Errorf("noop OpenSession err = nil, want non-nil")
	}
	// With no server there is no pane to confirm and no server pid to compare
	// against, which is what keeps the picker off the kill-and-resume path
	// outside tmux.
	if _, ok := m.FindPane(4242); ok {
		t.Error("noop FindPane reported a pane, want none")
	}
	if m.PaneExists("%3") {
		t.Error("noop PaneExists = true, want false")
	}
	if _, ok := m.ServerPID(); ok {
		t.Error("noop ServerPID reported a server, want none")
	}
	// Window naming is cosmetic, so its writes stay silent like Switch; its
	// two reads report false, which is what keeps the hook's rename guard
	// from acting on a zero value it never actually measured.
	if err := m.RenameWindow("%1", "x"); err != nil {
		t.Errorf("noop RenameWindow err = %v, want nil", err)
	}
	if err := m.SetAutomaticRename("%1", true); err != nil {
		t.Errorf("noop SetAutomaticRename err = %v, want nil", err)
	}
	if _, ok := m.WindowName("%1"); ok {
		t.Error("noop WindowName reported a name, want none")
	}
	if _, ok := m.WindowPaneCount("%1"); ok {
		t.Error("noop WindowPaneCount reported a count, want none")
	}
}

// The picker checks a ledger-recorded pane before switching to it, so "is this
// pane still here" has to be answerable from the pane table listPanes already
// builds -- no second tmux call, and no tmux at all in the test.
func TestPaneListed(t *testing.T) {
	panes := map[int]string{4242: "%3", 4243: "%7"}

	if !paneListed(panes, "%7") {
		t.Error("paneListed(%7) = false, want true")
	}
	// A pane of a tmux server that has since been replaced: this is common
	// because the pane id column keeps whatever value it had when the server
	// that owned it was still running, and a fresh server restarts pane ids
	// from %0.
	if paneListed(panes, "%99") {
		t.Error("paneListed(%99) = true, want false")
	}
	// "" is what an unrecorded pane looks like, and must not match anything.
	if paneListed(panes, "") {
		t.Error(`paneListed("") = true, want false`)
	}
	if paneListed(nil, "%7") {
		t.Error("paneListed over an empty table = true, want false")
	}
}
