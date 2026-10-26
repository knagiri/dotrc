package picker

import (
	"bytes"
	"database/sql"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

func seedDB(t *testing.T, stmts ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "q.db")
	t.Setenv("CLAUDE_QUEUE_DB", path)
	t.Setenv("CLAUDE_QUEUE_ASCII", "")
	t.Setenv("TMUX", "")
	conn, err := db.Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()
	for _, q := range stmts {
		if _, err := conn.Exec(q); err != nil {
			t.Fatalf("seed %q: %v", q, err)
		}
	}
	return path
}

func listOut(t *testing.T, flags ...string) string {
	t.Helper()
	var out bytes.Buffer
	run(append([]string{"--list"}, flags...), &out, func(*sql.DB) {}, func(string, []string) (string, error) {
		t.Error("--list started fzf")
		return "", nil
	})
	return out.String()
}

// A session whose process is gone is in the default listing, with no flag,
// under its own icon; a done one is not.
func TestListing_GoneShownByDefault(t *testing.T) {
	seedDB(t,
		"INSERT INTO sessions(session_id, terminated_at) VALUES ('gone-1', unixepoch() - 10), ('done-1', unixepoch() - 10)",
		"UPDATE sessions SET done_at = unixepoch() WHERE session_id = 'done-1'",
		"INSERT INTO events(session_id, event_type, state, created_at) VALUES ('gone-1', 'SessionEnd', 'ended', unixepoch() - 10), ('done-1', 'SessionEnd', 'ended', unixepoch() - 10)",
	)
	out := listOut(t)
	if !strings.Contains(out, "gone-1") || !strings.HasPrefix(out, emoji[db.StateGone]+"\t") {
		t.Errorf("gone session not listed with %s by default:\n%q", emoji[db.StateGone], out)
	}
	if strings.Contains(out, "done-1") {
		t.Errorf("done session listed:\n%q", out)
	}
}

// --show-resumable is a no-op kept so an old tmux bind still opens the picker:
// it is accepted, and the listing is the same as without it.
func TestShowResumableIsANoop(t *testing.T) {
	seedDB(t,
		"INSERT INTO sessions(session_id, terminated_at) VALUES ('gone-1', unixepoch() - 10)",
		"INSERT INTO events(session_id, event_type, state, created_at) VALUES ('gone-1', 'SessionEnd', 'ended', unixepoch() - 10)",
	)
	if a, b := listOut(t), listOut(t, "--show-resumable"); a != b || a == "" {
		t.Errorf("--show-resumable changed the listing:\n%q\nvs\n%q", a, b)
	}
}

// A delegate whose parent is only gone still has a delegator -- resuming it
// brings the delegation back -- so it is not marked as an orphan. A parent
// whose work is done is, since nobody is left to close the delegate.
func TestForest_GoneParentIsNotOrphan(t *testing.T) {
	const goneParent = "aaaaaaaa-0000"
	path := seedDB(t,
		"INSERT INTO sessions(session_id, terminated_at) VALUES ('aaaaaaaa-0000', unixepoch() - 10)",
		"INSERT INTO sessions(session_id, terminated_at, done_at) VALUES ('cccccccc-0000', unixepoch() - 10, unixepoch() - 10)",
		"INSERT INTO sessions(session_id) VALUES ('bbbbbbbb-0000'), ('dddddddd-0000')",
		"INSERT INTO events(session_id, event_type, state) VALUES ('aaaaaaaa-0000', 'SessionEnd', 'ended'), ('cccccccc-0000', 'SessionEnd', 'ended'), ('bbbbbbbb-0000', 'Stop', 'idle_done'), ('dddddddd-0000', 'Stop', 'idle_done')",
		"INSERT INTO session_links(child_short, parent_session_id) VALUES ('bbbbbbbb', 'aaaaaaaa-0000'), ('dddddddd', 'cccccccc-0000')",
	)
	conn, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	rows, err := db.ListRows(conn, db.ListOpts{ShowWorking: true, ShowStale: true})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, r := range buildForest(rows, forestOpts{
		Keep: func(db.Row) bool { return true },
		// Drop the gone parent from view, as the repo filter would, so the
		// child is a root and the parent's state decides its mark.
		InScope:    func(r db.Row) bool { return r.SessionID != goneParent },
		ParentOpen: openSessions(conn),
	}) {
		got[r.Row.SessionID] = r.Prefix
	}
	if p := got["bbbbbbbb-0000"]; p != unicodeTree.detached {
		t.Errorf("child of a gone parent prefix = %q, want %q (detached, not orphan)", p, unicodeTree.detached)
	}
	if p := got["dddddddd-0000"]; p != unicodeTree.orphan {
		t.Errorf("child of a done parent prefix = %q, want %q (orphan)", p, unicodeTree.orphan)
	}
}

// ctrl-x runs `claude-queue done` on the cursor row's session id and reloads
// with the same flags, and the picker hands it to fzf.
func TestFzfArgs_DoneBind(t *testing.T) {
	f := pickerFlags{ShowStale: true}
	bind := doneBind("/opt/x/claude-queue", f)
	if !strings.HasPrefix(bind, "ctrl-x:execute-silent(") || !strings.Contains(bind, ")+reload(") {
		t.Fatalf("done bind = %q, want ctrl-x:execute-silent(...)+reload(...)", bind)
	}
	m := regexp.MustCompile(`'/opt/x/claude-queue' done \{(\d+)\}`).FindStringSubmatch(bind)
	if m == nil {
		t.Fatalf("done bind %q does not run `done {N}`", bind)
	}
	n, _ := strconv.Atoi(m[1])
	row := db.Row{SessionID: "sid-123", EffectiveState: "idle_done", CreatedAt: nowMinus(60)}
	fields := strings.Split(FormatLine(row, "t", "w", nowUnix(), false), "\t")
	if n < 1 || n > len(fields) || fields[n-1] != "sid-123" {
		t.Errorf("{%d} does not address the session id in %q", n, fields)
	}
	if !strings.Contains(bind, "'picker' '--list' '--show-stale'") {
		t.Errorf("done bind %q does not reload with the same flags", bind)
	}

	// The interactive picker passes both binds.
	seedDB(t,
		"INSERT INTO sessions(session_id) VALUES ('a')",
		"INSERT INTO events(session_id, event_type, state) VALUES ('a', 'Stop', 'idle_done')",
	)
	var argv []string
	run(nil, &bytes.Buffer{}, func(*sql.DB) {}, func(_ string, args []string) (string, error) {
		argv = args
		return "", nil
	})
	var binds []string
	for i, a := range argv {
		if a == "--bind" && i+1 < len(argv) {
			binds = append(binds, strings.SplitN(argv[i+1], ":", 2)[0])
		}
	}
	if !slices.Equal(binds, []string{"tab", "ctrl-x"}) {
		t.Errorf("fzf binds = %v, want [tab ctrl-x]", binds)
	}
}
