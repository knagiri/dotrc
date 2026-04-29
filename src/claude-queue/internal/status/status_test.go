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
