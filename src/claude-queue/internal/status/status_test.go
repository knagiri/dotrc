package status

import (
	"testing"
)

func TestFormat_DefaultEmoji(t *testing.T) {
	counts := map[string]int{
		"awaiting_approval": 3,
		"idle_done":         2,
		"working":           1,
	}
	got := Format(counts, false)
	want := "⏳3 ✅2 ⚙️1"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestFormat_AsciiFallback(t *testing.T) {
	counts := map[string]int{"awaiting_approval": 1, "idle_done": 1}
	got := Format(counts, true)
	want := "[!]1 [.]1"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestFormat_OmitsZero(t *testing.T) {
	counts := map[string]int{"awaiting_approval": 0, "idle_done": 2}
	got := Format(counts, false)
	want := "✅2"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestFormat_EmptyReturnsEmpty(t *testing.T) {
	got := Format(map[string]int{}, false)
	if got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

// Gone sessions are open work but not running, and the status line counts what
// is running: a reboot must not light it up with every session it stopped.
func TestFormat_OmitsGone(t *testing.T) {
	got := Format(map[string]int{"gone": 40, "idle_done": 1}, false)
	if want := "✅1"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}
