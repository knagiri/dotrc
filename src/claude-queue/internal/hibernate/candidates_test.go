package hibernate

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

const (
	dirA = "/home/x/.claude"
	dirB = "/home/x/.claude-personal"
	now  = int64(1_800_000_000)
)

func openDB(t *testing.T) *sql.DB {
	t.Helper()
	conn, err := db.Open(filepath.Join(t.TempDir(), "q.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func exec(t *testing.T, conn *sql.DB, q string, args ...any) {
	t.Helper()
	if _, err := conn.Exec(q, args...); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
}

// session records a running, open session under dir whose latest event is
// state, agoSec before now.
func session(t *testing.T, conn *sql.DB, id, dir, state string, agoSec int64) {
	t.Helper()
	exec(t, conn, "INSERT INTO sessions(session_id, config_dir, transcript_path, tmux_pane) VALUES (?, ?, ?, '%1')",
		id, dir, "/transcripts/"+id+".jsonl")
	exec(t, conn, "INSERT INTO events(session_id, event_type, state, created_at) VALUES (?, 'Stop', ?, ?)",
		id, state, now-agoSec)
}

func idleAgent(id, kind string) roster.Agent {
	return roster.Agent{SessionID: id, PID: 4242, Kind: kind, Status: roster.StatusIdle}
}

func lists(m map[string][]roster.Agent) func(string) ([]roster.Agent, error) {
	return func(dir string) ([]roster.Agent, error) {
		agents, ok := m[dir]
		if !ok {
			return nil, errors.New("claude agents failed")
		}
		return agents, nil
	}
}

func noSend(string) (bool, error) { return false, nil }

func ids(cs []Candidate) []string {
	var out []string
	for _, c := range cs {
		out = append(out, c.SessionID)
	}
	return out
}

func skipReason(skips []Skip, id string) string {
	for _, s := range skips {
		if s.SessionID == id {
			return s.Reason
		}
	}
	return ""
}

const hours3 = 3 * 3600

func TestCandidates_IdleSessionPasses(t *testing.T) {
	conn := openDB(t)
	session(t, conn, "aaaaaaaa-1", dirA, "idle_done", hours3)
	cs, _, err := Candidates(conn, now, DefaultIdle,
		lists(map[string][]roster.Agent{dirA: {idleAgent("aaaaaaaa-1", roster.KindInteractive)}}), noSend)
	if err != nil {
		t.Fatal(err)
	}
	if len(cs) != 1 || cs[0].SessionID != "aaaaaaaa-1" || cs[0].Kind != roster.KindInteractive || cs[0].PID != 4242 || cs[0].ConfigDir != dirA {
		t.Fatalf("candidates = %+v", cs)
	}
}

func TestCandidates_BelowThresholdSkipped(t *testing.T) {
	conn := openDB(t)
	session(t, conn, "aaaaaaaa-1", dirA, "idle_done", 3600)
	cs, skips, err := Candidates(conn, now, DefaultIdle,
		lists(map[string][]roster.Agent{dirA: {idleAgent("aaaaaaaa-1", roster.KindBackground)}}), noSend)
	if err != nil {
		t.Fatal(err)
	}
	if len(cs) != 0 {
		t.Fatalf("candidates = %v, want none", ids(cs))
	}
	if r := skipReason(skips, "aaaaaaaa-1"); !strings.Contains(r, "threshold") {
		t.Fatalf("skip reason = %q", r)
	}
	// The same session clears a lower threshold, so the threshold is what held it.
	cs, _, _ = Candidates(conn, now, 30*time.Minute,
		lists(map[string][]roster.Agent{dirA: {idleAgent("aaaaaaaa-1", roster.KindBackground)}}), noSend)
	if len(cs) != 1 {
		t.Fatalf("with a 30m threshold, candidates = %v", ids(cs))
	}
}

func TestCandidates_AwaitingApprovalSkipped(t *testing.T) {
	conn := openDB(t)
	session(t, conn, "aaaaaaaa-1", dirA, "awaiting_approval", hours3)
	session(t, conn, "bbbbbbbb-1", dirA, "working", hours3)
	cs, skips, err := Candidates(conn, now, DefaultIdle, lists(map[string][]roster.Agent{dirA: {
		idleAgent("aaaaaaaa-1", roster.KindInteractive),
		idleAgent("bbbbbbbb-1", roster.KindInteractive),
	}}), noSend)
	if err != nil {
		t.Fatal(err)
	}
	if len(cs) != 0 {
		t.Fatalf("candidates = %v, want none", ids(cs))
	}
	if r := skipReason(skips, "aaaaaaaa-1"); !strings.Contains(r, "awaiting_approval") {
		t.Fatalf("skip reason = %q", r)
	}
}

func TestCandidates_RosterBusySkipped(t *testing.T) {
	conn := openDB(t)
	session(t, conn, "aaaaaaaa-1", dirA, "idle_done", hours3)
	busy := idleAgent("aaaaaaaa-1", roster.KindBackground)
	busy.Status = "busy"
	cs, skips, _ := Candidates(conn, now, DefaultIdle, lists(map[string][]roster.Agent{dirA: {busy}}), noSend)
	if len(cs) != 0 || !strings.Contains(skipReason(skips, "aaaaaaaa-1"), "busy") {
		t.Fatalf("candidates = %v, skips = %v", ids(cs), skips)
	}
}

func TestCandidates_DuplicateEntrySkipped(t *testing.T) {
	conn := openDB(t)
	session(t, conn, "aaaaaaaa-1", dirA, "idle_done", hours3)
	a := idleAgent("aaaaaaaa-1", roster.KindInteractive)
	cs, skips, _ := Candidates(conn, now, DefaultIdle, lists(map[string][]roster.Agent{dirA: {a, a}}), noSend)
	if len(cs) != 0 || !strings.Contains(skipReason(skips, "aaaaaaaa-1"), "listed 2 times") {
		t.Fatalf("candidates = %v, skips = %v", ids(cs), skips)
	}
}

func TestCandidates_GoneAndDoneIgnored(t *testing.T) {
	conn := openDB(t)
	session(t, conn, "aaaaaaaa-1", dirA, "idle_done", hours3)
	session(t, conn, "bbbbbbbb-1", dirA, "idle_done", hours3)
	exec(t, conn, "UPDATE sessions SET terminated_at = ? WHERE session_id = 'aaaaaaaa-1'", now)
	exec(t, conn, "UPDATE sessions SET done_at = ? WHERE session_id = 'bbbbbbbb-1'", now)
	cs, skips, _ := Candidates(conn, now, DefaultIdle, lists(map[string][]roster.Agent{dirA: {
		idleAgent("aaaaaaaa-1", roster.KindBackground),
		idleAgent("bbbbbbbb-1", roster.KindBackground),
	}}), noSend)
	if len(cs) != 0 || len(skips) != 0 {
		t.Fatalf("candidates = %v, skips = %v; gone and done sessions are not considered", ids(cs), skips)
	}
}

// Review focus 4: a pin marks a session as waiting on something external, and
// such a session is exactly the one whose process has nothing to do.
func TestCandidates_PinnedIncluded(t *testing.T) {
	conn := openDB(t)
	session(t, conn, "aaaaaaaa-1", dirA, "idle_done", hours3)
	exec(t, conn, "UPDATE sessions SET waiting_event_id = (SELECT MAX(id) FROM events) WHERE session_id = 'aaaaaaaa-1'")
	if !markedOf(t, conn, "aaaaaaaa-1") {
		t.Fatal("fixture: the session is not pinned")
	}
	cs, _, _ := Candidates(conn, now, DefaultIdle,
		lists(map[string][]roster.Agent{dirA: {idleAgent("aaaaaaaa-1", roster.KindInteractive)}}), noSend)
	if len(cs) != 1 {
		t.Fatalf("candidates = %v, want the pinned session", ids(cs))
	}
}

func markedOf(t *testing.T, conn *sql.DB, id string) bool {
	t.Helper()
	var m bool
	if err := conn.QueryRow("SELECT marked FROM queue WHERE session_id = ?", id).Scan(&m); err != nil {
		t.Fatal(err)
	}
	return m
}

// Review focus 5: an unreadable roster says nothing about its sessions, so they
// are left alone while another dir's are still considered.
func TestCandidates_UnreadableDirSkipped(t *testing.T) {
	conn := openDB(t)
	session(t, conn, "aaaaaaaa-1", dirA, "idle_done", hours3)
	session(t, conn, "bbbbbbbb-1", dirB, "idle_done", hours3)
	cs, skips, err := Candidates(conn, now, DefaultIdle,
		lists(map[string][]roster.Agent{dirB: {idleAgent("bbbbbbbb-1", roster.KindBackground)}}), noSend)
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(cs); len(got) != 1 || got[0] != "bbbbbbbb-1" {
		t.Fatalf("candidates = %v, want only the readable dir's session", got)
	}
	if r := skipReason(skips, "aaaaaaaa-1"); !strings.Contains(r, "unreadable") {
		t.Fatalf("skip reason = %q", r)
	}
}

func TestCandidates_SendMessageSkipped(t *testing.T) {
	conn := openDB(t)
	session(t, conn, "aaaaaaaa-1", dirA, "idle_done", hours3)
	sends := func(string) (bool, error) { return true, nil }
	cs, skips, _ := Candidates(conn, now, DefaultIdle,
		lists(map[string][]roster.Agent{dirA: {idleAgent("aaaaaaaa-1", roster.KindBackground)}}), sends)
	if len(cs) != 0 || !strings.Contains(skipReason(skips, "aaaaaaaa-1"), "SendMessage") {
		t.Fatalf("candidates = %v, skips = %v", ids(cs), skips)
	}
	// A transcript that cannot be read is held back the same way.
	broken := func(string) (bool, error) { return false, errors.New("no such file") }
	cs, skips, _ = Candidates(conn, now, DefaultIdle,
		lists(map[string][]roster.Agent{dirA: {idleAgent("aaaaaaaa-1", roster.KindBackground)}}), broken)
	if len(cs) != 0 || !strings.Contains(skipReason(skips, "aaaaaaaa-1"), "transcript") {
		t.Fatalf("candidates = %v, skips = %v", ids(cs), skips)
	}
}

// An orphan's question can never be answered: its delegator is done or no
// longer in the ledger. A delegator that is only gone is NOT orphaning -- it
// can be resumed and answer.
func TestCandidates_OrphanIgnoresSendMessage(t *testing.T) {
	conn := openDB(t)
	session(t, conn, "parentdn-1", dirA, "idle_done", 60)
	session(t, conn, "parentgn-1", dirA, "idle_done", 60)
	exec(t, conn, "UPDATE sessions SET done_at = ? WHERE session_id = 'parentdn-1'", now)
	exec(t, conn, "UPDATE sessions SET terminated_at = ? WHERE session_id = 'parentgn-1'", now)
	for _, c := range []struct{ child, parent string }{
		{"childdon-1", "parentdn-1"}, // parent done
		{"childmis-1", "parentms-1"}, // parent not in the ledger
		{"childgon-1", "parentgn-1"}, // parent only gone
	} {
		session(t, conn, c.child, dirA, "idle_done", hours3)
		if err := db.LinkSession(conn, c.child[:8], c.parent); err != nil {
			t.Fatal(err)
		}
	}
	sends := func(string) (bool, error) { return true, nil }
	cs, skips, err := Candidates(conn, now, DefaultIdle, lists(map[string][]roster.Agent{dirA: {
		idleAgent("childdon-1", roster.KindBackground),
		idleAgent("childmis-1", roster.KindBackground),
		idleAgent("childgon-1", roster.KindBackground),
	}}), sends)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, c := range cs {
		got[c.SessionID] = c.Orphan
	}
	if !got["childdon-1"] || !got["childmis-1"] || len(got) != 2 {
		t.Fatalf("candidates = %v, want the two orphans flagged", got)
	}
	if r := skipReason(skips, "childgon-1"); !strings.Contains(r, "SendMessage") {
		t.Fatalf("child of a gone parent: skip reason = %q", r)
	}
}

func writeTranscript(t *testing.T, lines ...string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "t.jsonl")
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

const (
	userPrompt   = `{"type":"user","message":{"content":"do the thing"}}`
	userBlocks   = `{"type":"user","message":{"content":[{"type":"text","text":"do it"}]}}`
	toolResult   = `{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}`
	metaUser     = `{"type":"user","isMeta":true,"message":{"content":"Base directory for this skill"}}`
	sendMsg      = `{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SendMessage"}]}}`
	bashUse      = `{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}`
	textReply    = `{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}`
	sideSend     = `{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"SendMessage"}]}}`
	sidePrompt   = `{"type":"user","isSidechain":true,"message":{"content":"subagent prompt"}}`
	otherEntries = `{"type":"summary","summary":"x"}`
	stringReply  = `{"type":"assistant","message":{"content":"done"}}`
	objectReply  = `{"type":"assistant","message":{"content":{"type":"text"}}}`
	numberReply  = `{"type":"assistant","message":{"content":7}}`
)

func TestLastTurnSendsMessage(t *testing.T) {
	cases := []struct {
		name  string
		lines []string
		want  bool
	}{
		{"send in the last turn", []string{userPrompt, bashUse, toolResult, sendMsg, textReply}, true},
		{"send in an earlier turn only", []string{userPrompt, sendMsg, userPrompt, textReply}, false},
		{"block-content prompt ends the turn", []string{userPrompt, sendMsg, userBlocks, textReply}, false},
		{"tool results do not end the turn", []string{userPrompt, sendMsg, toolResult, bashUse, toolResult, textReply}, true},
		{"meta entries do not end the turn", []string{userPrompt, sendMsg, metaUser, textReply}, true},
		{"sidechain send does not count", []string{userPrompt, sideSend, textReply}, false},
		{"sidechain prompt does not end the turn", []string{userPrompt, sendMsg, sidePrompt, textReply}, true},
		{"other entry types are ignored", []string{userPrompt, sendMsg, otherEntries}, true},
		{"no turns", []string{otherEntries}, false},
		{"string content has no tool_use", []string{userPrompt, sendMsg, userPrompt, stringReply}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := LastTurnSendsMessage(writeTranscript(t, c.lines...))
			if err != nil {
				t.Fatal(err)
			}
			if got != c.want {
				t.Fatalf("got %v, want %v", got, c.want)
			}
		})
	}
	t.Run("corrupt line is an error", func(t *testing.T) {
		if _, err := LastTurnSendsMessage(writeTranscript(t, userPrompt, "{not json")); err == nil {
			t.Fatal("want an error")
		}
	})
	for name, line := range map[string]string{"object": objectReply, "number": numberReply} {
		t.Run(name+" assistant content is an error", func(t *testing.T) {
			if _, err := LastTurnSendsMessage(writeTranscript(t, userPrompt, line)); err == nil {
				t.Fatal("want an error")
			}
		})
	}
	t.Run("missing file is an error", func(t *testing.T) {
		if _, err := LastTurnSendsMessage(filepath.Join(t.TempDir(), "absent.jsonl")); err == nil {
			t.Fatal("want an error")
		}
	})
}

func TestMinutes(t *testing.T) {
	for d, want := range map[time.Duration]string{
		7*time.Minute + 30*time.Second: "7m",
		2 * time.Hour:                  "2h",
		63 * time.Minute:               "1h3m",
	} {
		if got := Minutes(d); got != want {
			t.Errorf("Minutes(%s) = %q, want %q", d, got, want)
		}
	}
}
