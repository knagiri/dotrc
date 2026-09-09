package hook

import (
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/state"
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

// `claude --resume <uuid>` keeps the session id, so a session that already
// ended once comes back under the same primary key. Unless the upsert clears
// terminated_at, the row stays closed forever and the queue view -- which
// filters on terminated_at IS NULL -- never shows the resumed session again.
func TestDispatch_SessionStartAfterEnd_Resurrects(t *testing.T) {
	d := openTestDB(t)
	for _, ev := range []string{"SessionStart", "SessionEnd", "SessionStart"} {
		in := &Input{SessionID: "s", HookEventName: ev, Cwd: "/work"}
		if err := Dispatch(d, ev, in); err != nil {
			t.Fatalf("%s: %v", ev, err)
		}
	}

	var terminated sql.NullInt64
	if err := d.DB.QueryRow(
		"SELECT terminated_at FROM sessions WHERE session_id = 's'",
	).Scan(&terminated); err != nil {
		t.Fatalf("query terminated_at: %v", err)
	}
	if terminated.Valid {
		t.Errorf("terminated_at = %d after resume, want NULL", terminated.Int64)
	}

	var rows int
	if err := d.DB.QueryRow(
		"SELECT COUNT(*) FROM queue WHERE session_id = 's'",
	).Scan(&rows); err != nil {
		t.Fatalf("count queue: %v", err)
	}
	if rows != 1 {
		t.Errorf("queue rows for the resumed session = %d, want 1", rows)
	}
}

// The resurrect above must not leak into SessionEnd itself: that event upserts
// (clearing terminated_at) before setting it, so the ordering inside Dispatch is
// what keeps a genuine end closed.
func TestDispatch_SessionEndStillTerminatesAfterResurrect(t *testing.T) {
	d := openTestDB(t)
	for _, ev := range []string{"SessionStart", "SessionEnd", "SessionStart", "SessionEnd"} {
		in := &Input{SessionID: "s", HookEventName: ev}
		if err := Dispatch(d, ev, in); err != nil {
			t.Fatalf("%s: %v", ev, err)
		}
	}
	var terminated sql.NullInt64
	if err := d.DB.QueryRow(
		"SELECT terminated_at FROM sessions WHERE session_id = 's'",
	).Scan(&terminated); err != nil {
		t.Fatalf("query terminated_at: %v", err)
	}
	if !terminated.Valid {
		t.Error("terminated_at is NULL after the second SessionEnd, want it set")
	}
}

// queueRows counts how many rows the picker's view surfaces for a session. The
// view has two predicates -- terminated_at IS NULL and a latest event that is
// not 'ended' -- so it is the only assertion that covers both halves of a
// resurrection at once.
func queueRows(t *testing.T, d *Deps, id string) int {
	t.Helper()
	var n int
	if err := d.DB.QueryRow(
		"SELECT COUNT(*) FROM queue WHERE session_id = ?", id,
	).Scan(&n); err != nil {
		t.Fatalf("count queue rows for %s: %v", id, err)
	}
	return n
}

func terminatedAt(t *testing.T, d *Deps, id string) sql.NullInt64 {
	t.Helper()
	var at sql.NullInt64
	if err := d.DB.QueryRow(
		"SELECT terminated_at FROM sessions WHERE session_id = ?", id,
	).Scan(&at); err != nil {
		t.Fatalf("query terminated_at for %s: %v", id, err)
	}
	return at
}

// reconcileTerminate replays what a `claude-queue reconcile` pass does to a row
// it judges gone -- db.TerminateSession is literally the per-session call
// reconcile.Sweep makes -- and asserts the row really did leave the view, so a
// later "it came back" assertion cannot pass by never having left.
func reconcileTerminate(t *testing.T, d *Deps, id string) {
	t.Helper()
	if err := db.TerminateSession(d.DB, id); err != nil {
		t.Fatalf("TerminateSession(%s): %v", id, err)
	}
	if n := queueRows(t, d, id); n != 0 {
		t.Fatalf("session %s still has %d queue row(s) right after reconcile closed it", id, n)
	}
}

// reconcile closes every tracked row that `claude agents --json` does not list,
// and a session that is alive but absent from that roster is a misjudgement
// rather than an impossibility. This pins the misjudgement as RECOVERABLE: the
// next hook event from the still-running session puts it back in the queue view.
//
// The table covers every event that says "alive", not just SessionStart,
// because a session that reconcile wrongly closed is by definition already up
// and will never fire SessionStart again -- recovery that needed one would be no
// recovery at all for the case that motivates it.
//
// Both mechanisms are asserted separately, since either one regressing alone is
// enough to make the terminate permanent:
//   - upsertSession clears terminated_at (the view's terminated_at IS NULL)
//   - the event Dispatch inserts carries a non-'ended' state (the view's
//     e.state != 'ended'), superseding the synthetic ForcedEnd reconcile wrote
func TestDispatch_AfterReconcileTerminate_LiveEventRestoresRow(t *testing.T) {
	for _, ev := range []string{
		"SessionStart", "UserPromptSubmit",
		"PermissionRequest", "PermissionDenied",
		"PostToolUse", "PostToolUseFailure",
		"Stop", "StopFailure",
	} {
		t.Run(ev, func(t *testing.T) {
			d := openTestDB(t)
			seed := &Input{SessionID: "s", HookEventName: "SessionStart", Cwd: "/work"}
			if err := Dispatch(d, "SessionStart", seed); err != nil {
				t.Fatalf("seed SessionStart: %v", err)
			}
			reconcileTerminate(t, d, "s")

			in := &Input{SessionID: "s", HookEventName: ev, ToolName: "Bash"}
			if err := Dispatch(d, ev, in); err != nil {
				t.Fatalf("%s after reconcile: %v", ev, err)
			}

			if at := terminatedAt(t, d, "s"); at.Valid {
				t.Errorf("terminated_at = %d after %s, want NULL", at.Int64, ev)
			}
			if n := queueRows(t, d, "s"); n != 1 {
				t.Errorf("queue rows after %s = %d, want 1", ev, n)
			}
			want, _ := state.ForEvent(ev)
			var got string
			if err := d.DB.QueryRow(
				"SELECT raw_state FROM queue WHERE session_id = 's'",
			).Scan(&got); err != nil {
				t.Fatalf("query raw_state: %v", err)
			}
			if got != want {
				t.Errorf("raw_state = %q, want %q", got, want)
			}
		})
	}
}

// The recovery above must not extend to SessionEnd. It is the one event that is
// not evidence of life, so a session reconcile closed and that then genuinely
// ends has to stay closed -- otherwise the upsert's terminated_at = NULL would
// reopen rows on the way out.
func TestDispatch_AfterReconcileTerminate_SessionEndStaysClosed(t *testing.T) {
	d := openTestDB(t)
	seed := &Input{SessionID: "s", HookEventName: "SessionStart", Cwd: "/work"}
	if err := Dispatch(d, "SessionStart", seed); err != nil {
		t.Fatalf("seed SessionStart: %v", err)
	}
	reconcileTerminate(t, d, "s")

	end := &Input{SessionID: "s", HookEventName: "SessionEnd", Reason: "other"}
	if err := Dispatch(d, "SessionEnd", end); err != nil {
		t.Fatalf("SessionEnd after reconcile: %v", err)
	}

	if at := terminatedAt(t, d, "s"); !at.Valid {
		t.Error("terminated_at is NULL after SessionEnd, want it set")
	}
	if n := queueRows(t, d, "s"); n != 0 {
		t.Errorf("queue rows after SessionEnd = %d, want 0", n)
	}
}

func TestDispatch_NonSessionStart_BackfillsTmuxPane(t *testing.T) {
	// Simulates the real bug: SessionStart hook was missed, so the session
	// row exists with NULL tmux_pane (created defensively by a later event
	// or pre-existing). A subsequent PostToolUse event should backfill the
	// pane so picker can switch to it.
	d := openTestDB(t)
	d.Pane = "%42"

	// Seed: session row exists with no pane (e.g. created by an earlier
	// non-SessionStart event under the previous code path).
	_, err := d.DB.Exec("INSERT INTO sessions(session_id) VALUES ('s')")
	if err != nil {
		t.Fatalf("seed session: %v", err)
	}

	in := &Input{SessionID: "s", HookEventName: "PostToolUse", ToolName: "Bash"}
	if err := Dispatch(d, "PostToolUse", in); err != nil {
		t.Fatalf("Dispatch: %v", err)
	}

	var pane sql.NullString
	err = d.DB.QueryRow("SELECT tmux_pane FROM sessions WHERE session_id = 's'").Scan(&pane)
	if err != nil {
		t.Fatalf("query pane: %v", err)
	}
	if !pane.Valid || pane.String != "%42" {
		t.Errorf("tmux_pane = %v, want %%42", pane)
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

func TestDispatch_SessionEnd_TriggersGC(t *testing.T) {
	d := openTestDB(t)

	// Pre-seed an ancient terminated session that should be gc'd.
	_, err := d.DB.Exec(`
		INSERT INTO sessions(session_id, terminated_at) VALUES ('ancient', unixepoch() - 700000);
	`)
	if err != nil {
		t.Fatalf("seed ancient: %v", err)
	}
	_, err = d.DB.Exec(`
		INSERT INTO events(session_id, event_type, state, created_at)
		VALUES ('ancient', 'SessionEnd', 'ended', unixepoch() - 700000);
	`)
	if err != nil {
		t.Fatalf("seed ancient event: %v", err)
	}

	// Now run a real lifecycle on a different session.
	for _, ev := range []string{"SessionStart", "SessionEnd"} {
		in := &Input{SessionID: "s", HookEventName: ev}
		if err := Dispatch(d, ev, in); err != nil {
			t.Fatalf("%s: %v", ev, err)
		}
	}

	var n int
	_ = d.DB.QueryRow("SELECT COUNT(*) FROM sessions WHERE session_id = 'ancient'").Scan(&n)
	if n != 0 {
		t.Errorf("ancient should be gc'd; count = %d", n)
	}
}
