package db

import (
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenAppliesSchemaAndPragmas(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")

	conn, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	var jm string
	if err := conn.QueryRow("PRAGMA journal_mode").Scan(&jm); err != nil {
		t.Fatalf("journal_mode pragma: %v", err)
	}
	if jm != "wal" {
		t.Errorf("journal_mode = %q, want %q", jm, "wal")
	}

	// sessions / events / queue should exist.
	wantObjects := []string{"sessions", "events", "queue"}
	for _, name := range wantObjects {
		var got string
		err := conn.QueryRow(
			"SELECT name FROM sqlite_master WHERE name = ?", name,
		).Scan(&got)
		if err != nil {
			t.Errorf("object %q not found: %v", name, err)
		}
	}
}

func TestOpenIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")

	for i := 0; i < 3; i++ {
		conn, err := Open(path)
		if err != nil {
			t.Fatalf("Open iter %d: %v", i, err)
		}
		conn.Close()
	}
}

func insertSession(t *testing.T, conn *sql.DB, id, pane string) {
	t.Helper()
	_, err := conn.Exec(
		"INSERT INTO sessions(session_id, tmux_pane) VALUES (?, ?)", id, pane,
	)
	if err != nil {
		t.Fatalf("insert session: %v", err)
	}
}

func insertEvent(t *testing.T, conn *sql.DB, sid, evType, state string, agoSec int64) {
	t.Helper()
	_, err := conn.Exec(
		"INSERT INTO events(session_id, event_type, state, created_at) VALUES (?, ?, ?, unixepoch() - ?)",
		sid, evType, state, agoSec,
	)
	if err != nil {
		t.Fatalf("insert event: %v", err)
	}
}

func insertEventPayload(t *testing.T, conn *sql.DB, sid, evType, state, payload string, agoSec int64) {
	t.Helper()
	_, err := conn.Exec(
		"INSERT INTO events(session_id, event_type, state, payload, created_at) VALUES (?, ?, ?, ?, unixepoch() - ?)",
		sid, evType, state, payload, agoSec,
	)
	if err != nil {
		t.Fatalf("insert event: %v", err)
	}
}

func terminate(t *testing.T, conn *sql.DB, sid string, agoSec int64) {
	t.Helper()
	_, err := conn.Exec(
		"UPDATE sessions SET terminated_at = unixepoch() - ? WHERE session_id = ?", agoSec, sid,
	)
	if err != nil {
		t.Fatalf("terminate %s: %v", sid, err)
	}
}

func TestCounts(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "a", "%1")
	insertSession(t, conn, "b", "%2")
	insertSession(t, conn, "c", "%3")
	insertEvent(t, conn, "a", "PermissionRequest", "awaiting_approval", 5)
	insertEvent(t, conn, "b", "Stop", "idle_done", 10)
	insertEvent(t, conn, "c", "UserPromptSubmit", "working", 3)

	got, err := Counts(conn)
	if err != nil {
		t.Fatalf("Counts: %v", err)
	}
	if got["awaiting_approval"] != 1 {
		t.Errorf("awaiting_approval = %d, want 1", got["awaiting_approval"])
	}
	if got["idle_done"] != 1 {
		t.Errorf("idle_done = %d, want 1", got["idle_done"])
	}
	if got["working"] != 1 {
		t.Errorf("working = %d, want 1", got["working"])
	}
}

func TestListRows_SortsByPriorityThenRecency(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "w", "%1")
	insertSession(t, conn, "i", "%2")
	insertSession(t, conn, "p", "%3")

	insertEvent(t, conn, "w", "UserPromptSubmit", "working", 60)
	insertEvent(t, conn, "i", "Stop", "idle_done", 60)
	insertEvent(t, conn, "p", "PermissionRequest", "awaiting_approval", 60)

	rows, err := ListRows(conn, ListOpts{})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("len(rows) = %d, want 2 (working filtered by default)", len(rows))
	}
	if rows[0].SessionID != "p" {
		t.Errorf("rows[0] = %q, want p (awaiting_approval first)", rows[0].SessionID)
	}
	if rows[1].SessionID != "i" {
		t.Errorf("rows[1] = %q, want i", rows[1].SessionID)
	}
}

// The reason filter is the whole point of the candidate query: an end a human
// typed at the REPL prompt is a stopping point, while a signal-driven end or a
// ForcedEnd synthesised by reconcile is a session that was cut off.
func TestResumableCandidates_FiltersByEndReason(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "r.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	// The ends that should come back.
	insertSession(t, conn, "signal", "%1")
	insertEvent(t, conn, "signal", "Stop", "idle_done", 400)
	insertEventPayload(t, conn, "signal", "SessionEnd", "ended", `{"reason":"other"}`, 300)
	terminate(t, conn, "signal", 300)

	insertSession(t, conn, "forced", "%2")
	insertEvent(t, conn, "forced", "UserPromptSubmit", "working", 400)
	insertEvent(t, conn, "forced", "ForcedEnd", "ended", 300) // no payload at all
	terminate(t, conn, "forced", 300)

	// A SessionEnd with no reason recorded stores an empty payload string, which
	// json_extract rejects as malformed rather than reading as absent. It must
	// not take the query down or drop the row.
	insertSession(t, conn, "noreason", "%3")
	insertEvent(t, conn, "noreason", "Stop", "idle_done", 400)
	insertEventPayload(t, conn, "noreason", "SessionEnd", "ended", "", 300)
	terminate(t, conn, "noreason", 300)

	// The ends that should not.
	insertSession(t, conn, "typedexit", "%4")
	insertEvent(t, conn, "typedexit", "Stop", "idle_done", 400)
	insertEventPayload(t, conn, "typedexit", "SessionEnd", "ended", `{"reason":"prompt_input_exit"}`, 300)
	terminate(t, conn, "typedexit", 300)

	// Still live: it belongs to the queue view, not here.
	insertSession(t, conn, "live", "%5")
	insertEvent(t, conn, "live", "Stop", "idle_done", 60)

	got, err := ResumableCandidates(conn)
	if err != nil {
		t.Fatalf("ResumableCandidates: %v", err)
	}
	found := map[string]Row{}
	for _, r := range got {
		found[r.SessionID] = r
	}
	for _, want := range []string{"signal", "forced", "noreason"} {
		if _, ok := found[want]; !ok {
			t.Errorf("session %q missing from the candidates", want)
		}
	}
	for _, unwanted := range []string{"typedexit", "live"} {
		if _, ok := found[unwanted]; ok {
			t.Errorf("session %q should not be a candidate", unwanted)
		}
	}
	if len(got) != 3 {
		t.Fatalf("len(candidates) = %d, want 3: %+v", len(got), got)
	}

	// Every candidate is labelled with the pseudo state the picker renders, and
	// carries the state it was in before the end so the summary can name it.
	if s := found["forced"]; s.EffectiveState != StateResumable || s.PriorState.String != "working" {
		t.Errorf("forced = {%q, %q}, want {%q, working}", s.EffectiveState, s.PriorState.String, StateResumable)
	}
	if s := found["signal"]; s.PriorState.String != "idle_done" {
		t.Errorf("signal prior state = %q, want idle_done", s.PriorState.String)
	}
}

// Resumable rows sort behind every live row, then interrupted before finished,
// then newest first -- so a host that came back up offers the work that was
// actually in flight at the top.
func TestResumableCandidates_Ordering(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "o.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	type seed struct {
		id    string
		prior string
		ago   int64
	}
	// Inserted in an order that matches neither the priority nor the recency
	// the result must come back in.
	for _, s := range []seed{
		{"done-old", "idle_done", 500},
		{"work-old", "working", 400},
		{"appr-new", "awaiting_approval", 100},
		{"done-new", "idle_done", 200},
		{"work-new", "working", 150},
	} {
		insertSession(t, conn, s.id, "")
		insertEvent(t, conn, s.id, "Stop", s.prior, s.ago+50)
		insertEvent(t, conn, s.id, "ForcedEnd", "ended", s.ago)
		terminate(t, conn, s.id, s.ago)
	}

	got, err := ResumableCandidates(conn)
	if err != nil {
		t.Fatalf("ResumableCandidates: %v", err)
	}
	var ids []string
	for _, r := range got {
		ids = append(ids, r.SessionID)
		if r.Priority <= 5 {
			t.Errorf("%s has priority %d, which would sort it among the live rows",
				r.SessionID, r.Priority)
		}
	}
	want := []string{"appr-new", "work-new", "work-old", "done-new", "done-old"}
	if strings.Join(ids, ",") != strings.Join(want, ",") {
		t.Errorf("order = %v, want %v", ids, want)
	}
}

// A session whose only event is the end has no prior state to report, and must
// still be offered rather than dropped by the join that looks for one.
func TestResumableCandidates_NoPriorState(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "p.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "bare", "%1")
	insertEvent(t, conn, "bare", "ForcedEnd", "ended", 100)
	terminate(t, conn, "bare", 100)

	got, err := ResumableCandidates(conn)
	if err != nil {
		t.Fatalf("ResumableCandidates: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1", len(got))
	}
	if got[0].PriorState.Valid {
		t.Errorf("PriorState = %q, want NULL", got[0].PriorState.String)
	}
	if got[0].Priority != priorityResumableIdle {
		t.Errorf("Priority = %d, want %d", got[0].Priority, priorityResumableIdle)
	}
}

// The prior state is what the session was last DOING, which takes two things
// the naive "the event before the last one" does not give. A session that ended,
// was resumed and ended again has to report the second run, not the first. And
// end events do not count as a prior state: 'ended' says nothing about the work,
// so a row carrying more than one of them in a row -- the shape a resurrected
// session leaves behind -- must be looked past rather than reported as
// "resumable (was ended)" and sorted as if it had finished cleanly.
func TestResumableCandidates_PriorStateIsTheLastWorkingState(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "q.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "twice", "%1")
	// First run, closed cleanly.
	insertEvent(t, conn, "twice", "Stop", "idle_done", 900)
	insertEventPayload(t, conn, "twice", "SessionEnd", "ended", `{"reason":"other"}`, 800)
	// Resumed, then cut off mid-approval -- and closed twice over.
	insertEvent(t, conn, "twice", "SessionStart", "working", 700)
	insertEvent(t, conn, "twice", "PermissionRequest", "awaiting_approval", 600)
	insertEventPayload(t, conn, "twice", "SessionEnd", "ended", `{"reason":"other"}`, 550)
	insertEvent(t, conn, "twice", "ForcedEnd", "ended", 500)
	terminate(t, conn, "twice", 500)

	got, err := ResumableCandidates(conn)
	if err != nil {
		t.Fatalf("ResumableCandidates: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1 (only the last event decides)", len(got))
	}
	if got[0].PriorState.String != "awaiting_approval" {
		t.Errorf("PriorState = %q, want awaiting_approval", got[0].PriorState.String)
	}
	if got[0].Priority != priorityResumable {
		t.Errorf("Priority = %d, want %d (interrupted, so ahead of the finished ones)",
			got[0].Priority, priorityResumable)
	}
}

// The picker's filesystem filter reads cwd and transcript_path off the row, so
// the candidate query has to carry them through.
func TestResumableCandidates_CarriesResumeInputs(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "c2.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	if _, err := conn.Exec(`
		INSERT INTO sessions(session_id, tmux_pane, cwd, transcript_path)
		VALUES ('s', '%1', '/w/a', '/t/a.jsonl')
	`); err != nil {
		t.Fatalf("insert session: %v", err)
	}
	insertEvent(t, conn, "s", "ForcedEnd", "ended", 10)
	terminate(t, conn, "s", 10)

	got, err := ResumableCandidates(conn)
	if err != nil {
		t.Fatalf("ResumableCandidates: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1", len(got))
	}
	if got[0].Cwd.String != "/w/a" || got[0].TranscriptPath.String != "/t/a.jsonl" {
		t.Errorf("cwd/transcript = %q/%q, want /w/a and /t/a.jsonl",
			got[0].Cwd.String, got[0].TranscriptPath.String)
	}
	// The pane, by contrast, must NOT come through even though the ledger still
	// holds one. It names a pane of a process that has ended, and the picker's
	// last-resort fallback would trust it whenever the roster cannot be read --
	// switching to whatever unrelated pane inherited that id on the new server
	// instead of resuming the conversation.
	if got[0].TmuxPane.Valid {
		t.Errorf("tmux_pane = %q, want NULL: a terminated row's pane is never its own",
			got[0].TmuxPane.String)
	}
}

func TestTerminateSession(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "s", "%1")
	insertEvent(t, conn, "s", "PermissionRequest", "awaiting_approval", 5)

	if err := TerminateSession(conn, "s"); err != nil {
		t.Fatalf("TerminateSession: %v", err)
	}

	var terminated int64
	_ = conn.QueryRow(
		"SELECT COALESCE(terminated_at, 0) FROM sessions WHERE session_id = ?", "s",
	).Scan(&terminated)
	if terminated == 0 {
		t.Error("terminated_at should be set")
	}

	var n int
	_ = conn.QueryRow(
		"SELECT COUNT(*) FROM events WHERE session_id = 's' AND event_type = 'ForcedEnd'",
	).Scan(&n)
	if n != 1 {
		t.Errorf("expected 1 ForcedEnd event, got %d", n)
	}

	// View should no longer surface the terminated session.
	rows, err := ListRows(conn, ListOpts{ShowWorking: true, ShowStale: true})
	if err != nil {
		t.Fatalf("ListRows: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("ListRows after Terminate = %d, want 0", len(rows))
	}
}

func TestGC_DeletesOldEndedSessions(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	insertSession(t, conn, "old", "%1")
	_, err = conn.Exec("UPDATE sessions SET terminated_at = unixepoch() - 700000 WHERE session_id = 'old'")
	if err != nil {
		t.Fatalf("update terminated: %v", err)
	}
	insertEvent(t, conn, "old", "SessionEnd", "ended", 700000)

	insertSession(t, conn, "recent", "%2")
	_, _ = conn.Exec("UPDATE sessions SET terminated_at = unixepoch() - 100 WHERE session_id = 'recent'")
	insertEvent(t, conn, "recent", "SessionEnd", "ended", 100)

	if err := GC(conn, 7*24*3600); err != nil {
		t.Fatalf("GC: %v", err)
	}

	var n int
	_ = conn.QueryRow("SELECT COUNT(*) FROM sessions WHERE session_id = 'old'").Scan(&n)
	if n != 0 {
		t.Errorf("old session should be deleted; count = %d", n)
	}
	_ = conn.QueryRow("SELECT COUNT(*) FROM sessions WHERE session_id = 'recent'").Scan(&n)
	if n != 1 {
		t.Errorf("recent session should be kept; count = %d", n)
	}
}
