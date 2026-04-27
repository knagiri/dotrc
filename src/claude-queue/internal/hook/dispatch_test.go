package hook

import (
	"path/filepath"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

func openTestDB(t *testing.T) *Deps {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	conn, err := db.Open(path)
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	return &Deps{DB: conn, Pane: "%1"}
}

func TestDispatch_SessionStart_CreatesSessionRow(t *testing.T) {
	d := openTestDB(t)
	in := &Input{
		SessionID:      "sess-1",
		TranscriptPath: "/tmp/x.jsonl",
		Cwd:            "/work",
		HookEventName:  "SessionStart",
		Source:         "startup",
	}

	if err := Dispatch(d, "SessionStart", in); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	var pane, cwd string
	err := d.DB.QueryRow(
		"SELECT tmux_pane, cwd FROM sessions WHERE session_id = ?",
		"sess-1",
	).Scan(&pane, &cwd)
	if err != nil {
		t.Fatalf("query sessions: %v", err)
	}
	if pane != "%1" {
		t.Errorf("tmux_pane = %q, want %q", pane, "%1")
	}
	if cwd != "/work" {
		t.Errorf("cwd = %q, want %q", cwd, "/work")
	}

	var state string
	err = d.DB.QueryRow(
		"SELECT state FROM events WHERE session_id = ? ORDER BY id DESC LIMIT 1",
		"sess-1",
	).Scan(&state)
	if err != nil {
		t.Fatalf("query events: %v", err)
	}
	if state != "working" {
		t.Errorf("state = %q, want %q", state, "working")
	}
}

func TestDispatch_PermissionRequest_SetsAwaiting(t *testing.T) {
	d := openTestDB(t)
	start := &Input{SessionID: "s", HookEventName: "SessionStart"}
	if err := Dispatch(d, "SessionStart", start); err != nil {
		t.Fatalf("SessionStart: %v", err)
	}
	perm := &Input{SessionID: "s", HookEventName: "PermissionRequest", ToolName: "Bash"}
	if err := Dispatch(d, "PermissionRequest", perm); err != nil {
		t.Fatalf("PermissionRequest: %v", err)
	}

	var state string
	err := d.DB.QueryRow(
		"SELECT state FROM events WHERE session_id = ? ORDER BY id DESC LIMIT 1", "s",
	).Scan(&state)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if state != "awaiting_approval" {
		t.Errorf("state = %q, want awaiting_approval", state)
	}
}

func TestDispatch_PermissionDenied_ReturnsToWorking(t *testing.T) {
	d := openTestDB(t)
	for _, ev := range []string{"SessionStart", "PermissionRequest", "PermissionDenied"} {
		in := &Input{SessionID: "s", HookEventName: ev, ToolName: "Bash"}
		if err := Dispatch(d, ev, in); err != nil {
			t.Fatalf("%s: %v", ev, err)
		}
	}
	var state string
	_ = d.DB.QueryRow(
		"SELECT state FROM events WHERE session_id = ? ORDER BY id DESC LIMIT 1", "s",
	).Scan(&state)
	if state != "working" {
		t.Errorf("state = %q, want working", state)
	}
}

func TestDispatch_L3_EndsPriorSessionOnSamePane(t *testing.T) {
	d := openTestDB(t)
	d.Pane = "%7"

	first := &Input{SessionID: "old", HookEventName: "SessionStart"}
	if err := Dispatch(d, "SessionStart", first); err != nil {
		t.Fatalf("first SessionStart: %v", err)
	}

	second := &Input{SessionID: "new", HookEventName: "SessionStart"}
	if err := Dispatch(d, "SessionStart", second); err != nil {
		t.Fatalf("second SessionStart: %v", err)
	}

	var terminated int64
	err := d.DB.QueryRow(
		"SELECT COALESCE(terminated_at, 0) FROM sessions WHERE session_id = ?", "old",
	).Scan(&terminated)
	if err != nil {
		t.Fatalf("query old: %v", err)
	}
	if terminated == 0 {
		t.Errorf("old session should have terminated_at set; got 0")
	}

	var rows int
	err = d.DB.QueryRow(
		"SELECT COUNT(*) FROM events WHERE session_id = 'old' AND event_type = 'ForcedEnd'",
	).Scan(&rows)
	if err != nil {
		t.Fatalf("count ForcedEnd: %v", err)
	}
	if rows != 1 {
		t.Errorf("expected 1 ForcedEnd event, got %d", rows)
	}
}

func TestDispatch_SessionEnd_SetsTerminated(t *testing.T) {
	d := openTestDB(t)
	for _, ev := range []string{"SessionStart", "SessionEnd"} {
		in := &Input{SessionID: "s", HookEventName: ev, Reason: "logout"}
		if err := Dispatch(d, ev, in); err != nil {
			t.Fatalf("%s: %v", ev, err)
		}
	}
	var terminated int64
	_ = d.DB.QueryRow(
		"SELECT COALESCE(terminated_at, 0) FROM sessions WHERE session_id = ?", "s",
	).Scan(&terminated)
	if terminated == 0 {
		t.Error("terminated_at should be set after SessionEnd")
	}
}

func TestDispatch_UnknownEvent_NoOp(t *testing.T) {
	d := openTestDB(t)
	in := &Input{SessionID: "s", HookEventName: "WeirdEvent"}
	if err := Dispatch(d, "WeirdEvent", in); err != nil {
		t.Errorf("Dispatch should no-op for unknown events, got err: %v", err)
	}
	var rows int
	_ = d.DB.QueryRow("SELECT COUNT(*) FROM events").Scan(&rows)
	if rows != 0 {
		t.Errorf("expected no events, got %d", rows)
	}
}
