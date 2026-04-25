package state

import "testing"

func TestForEvent(t *testing.T) {
	cases := []struct {
		event     string
		wantState string
		wantOK    bool
	}{
		{"SessionStart", "working", true},
		{"UserPromptSubmit", "working", true},
		{"PermissionRequest", "awaiting_approval", true},
		{"PermissionDenied", "working", true},
		{"PostToolUse", "working", true},
		{"PostToolUseFailure", "working", true},
		{"Stop", "idle_done", true},
		{"StopFailure", "idle_done", true},
		{"SessionEnd", "ended", true},
		{"ForcedEnd", "ended", true},
		{"unknown", "", false},
	}

	for _, c := range cases {
		got, ok := ForEvent(c.event)
		if ok != c.wantOK {
			t.Errorf("ForEvent(%q) ok = %v, want %v", c.event, ok, c.wantOK)
		}
		if got != c.wantState {
			t.Errorf("ForEvent(%q) state = %q, want %q", c.event, got, c.wantState)
		}
	}
}
