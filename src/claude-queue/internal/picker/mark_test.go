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
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// A marked row swaps its icon and nothing else, whatever the state: a parked
// session is one the user meant to return to.
func TestFormatLine_MarkedIcon(t *testing.T) {
	for _, tc := range []struct {
		state  string
		marked bool
		ascii  bool
		want   string
	}{
		{"idle_done", true, false, "📌"},
		{"idle_done", true, true, "[P]"},
		{"awaiting_approval", true, false, "📌"},
		{"awaiting_approval", true, true, "[P]"},
		{"awaiting_approval", false, false, "⏳"},
		{"idle_done", false, true, "[.]"},
	} {
		row := db.Row{SessionID: "s", EffectiveState: tc.state, RawState: "idle_done", CreatedAt: nowMinus(60), Marked: tc.marked}
		unmarked := row
		unmarked.Marked = false
		got := strings.Split(FormatLine(row, "t", "w", nowUnix(), tc.ascii), "\t")
		base := strings.Split(FormatLine(unmarked, "t", "w", nowUnix(), tc.ascii), "\t")
		if got[colIcon] != tc.want {
			t.Errorf("%s marked=%v ascii=%v: icon = %q, want %q", tc.state, tc.marked, tc.ascii, got[colIcon], tc.want)
		}
		// Every other column is the unmarked row's.
		if !slices.Equal(got[colIcon+1:], base[colIcon+1:]) {
			t.Errorf("%s marked=%v: columns past the icon changed: %q vs %q", tc.state, tc.marked, got, base)
		}
	}
	// [P] must not collide with a state's ASCII icon.
	for k, v := range ascii {
		if k != iconMarked && v == ascii[iconMarked] {
			t.Errorf("ascii marked icon %q collides with state %s", v, k)
		}
	}
}

// The Tab bind names the row by {N}; N has to land on the hidden session id
// column of a line FormatLine actually rendered, or Tab marks another field's
// value -- a pane id, a cwd -- which ToggleMark silently treats as unknown.
func TestTabBind_PointsAtSessionID(t *testing.T) {
	bind := tabBind("/opt/x/claude-queue", pickerFlags{})
	m := regexp.MustCompile(`mark \{(\d+)\}`).FindStringSubmatch(bind)
	if m == nil {
		t.Fatalf("tab bind %q has no mark {N}", bind)
	}
	n, _ := strconv.Atoi(m[1])
	row := db.Row{SessionID: "sid-123", EffectiveState: "idle_done", CreatedAt: nowMinus(60)}
	fields := strings.Split(FormatLine(row, "t", "w", nowUnix(), false), "\t")
	if n < 1 || n > len(fields) || fields[n-1] != "sid-123" {
		t.Errorf("{%d} does not address the session id in %q", n, fields)
	}
	if !strings.HasPrefix(bind, "tab:execute-silent(") || !strings.Contains(bind, ")+reload(") {
		t.Errorf("tab bind = %q, want execute-silent(...)+reload(...)", bind)
	}
	if !slices.Contains(fzfArgs(bind), bind) {
		t.Errorf("fzfArgs does not carry the tab bind")
	}
}

func TestTabBind_QuotesAndDelimits(t *testing.T) {
	bind := tabBind("/a b/it's(1)/claude-queue", pickerFlags{ShowWorking: true})
	q := `'/a b/it'\''s(1)/claude-queue'`
	if !strings.Contains(bind, q+" mark ") || !strings.Contains(bind, q+" 'picker' '--list' '--show-working'") {
		t.Errorf("binary path not shell-quoted in %q", bind)
	}
	// A ')' in the path must not end the action argument early.
	if strings.Contains(bind, "execute-silent(") || strings.Contains(bind, "reload(") {
		t.Errorf("bind %q used () around an argument containing ')'", bind)
	}
}

func TestListArgs(t *testing.T) {
	got := pickerFlags{ShowWorking: true, RepoScope: true}.listArgs()
	want := []string{"picker", "--list", "--show-working", "--repo-scope"}
	if !slices.Equal(got, want) {
		t.Errorf("listArgs = %v, want %v", got, want)
	}
	if got := (pickerFlags{}).listArgs(); !slices.Equal(got, []string{"picker", "--list"}) {
		t.Errorf("listArgs() = %v", got)
	}
}

// The Tab reload runs inside fzf and does not ask tmux for the pane, so the
// current-session mark survives Tab only if the pane rides along in its argv.
func TestListArgs_CurrentPane(t *testing.T) {
	got := pickerFlags{ShowWorking: true, CurrentPane: "%7"}.listArgs()
	want := []string{"picker", "--list", "--show-working", "--current-pane", "%7"}
	if !slices.Equal(got, want) {
		t.Errorf("listArgs = %v, want %v", got, want)
	}
	if slices.Contains((pickerFlags{}).listArgs(), "--current-pane") {
		t.Errorf("listArgs passed --current-pane with no pane")
	}
	if bind := tabBind("/x/claude-queue", pickerFlags{CurrentPane: "%7"}); !strings.Contains(bind, "'--current-pane' '%7' 2>/dev/null") {
		t.Errorf("tab bind %q does not reload with the current pane", bind)
	}
}

// --list is what Tab reloads the popup with, so it must print exactly what the
// interactive picker handed fzf for the same flags -- and the interactive
// picker's bind must ask --list for those same flags.
func TestListModeMatchesInteractiveInput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "q.db")
	t.Setenv("CLAUDE_QUEUE_DB", path)
	t.Setenv("CLAUDE_QUEUE_ASCII", "")
	// Outside tmux, so the interactive path cannot pick up the pane this test
	// happens to run in; the current pane comes only from the flag cases below.
	t.Setenv("TMUX", "")
	conn, err := db.Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	for _, q := range []string{
		"INSERT INTO sessions(session_id, tmux_pane) VALUES ('a', '%7'), ('b', '%8'), ('c', NULL)",
		"INSERT INTO events(session_id, event_type, state, created_at) VALUES ('a', 'Stop', 'idle_done', unixepoch() - 3700)",
		"INSERT INTO events(session_id, event_type, state, created_at) VALUES ('b', 'UserPromptSubmit', 'working', unixepoch() - 3700)",
		"INSERT INTO events(session_id, event_type, state, created_at) VALUES ('c', 'Stop', 'idle_done', unixepoch() - 20000)",
	} {
		if _, err := conn.Exec(q); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	if _, err := db.ToggleMark(conn, "a"); err != nil {
		t.Fatalf("ToggleMark: %v", err)
	}
	conn.Close()

	// One clock for both paths, so the comparison below sees only the path.
	now := time.Now().Unix()
	for _, flags := range [][]string{nil, {"--show-working"}, {"--show-working", "--current-pane", "%7"}} {
		var fzfInput string
		var fzfArgv []string
		run(flags, &bytes.Buffer{}, func(c *sql.DB) {}, func(in string, args []string) (string, error) {
			fzfInput, fzfArgv = in, args
			return "", nil
		}, now)
		var out bytes.Buffer
		run(append([]string{"--list"}, flags...), &out, func(c *sql.DB) { t.Error("--list ran the reconcile sweep") }, func(string, []string) (string, error) {
			t.Error("--list started fzf")
			return "", nil
		}, now)
		if fzfInput == "" {
			t.Fatalf("flags %v: interactive path gave fzf nothing", flags)
		}
		if !strings.Contains(fzfInput, "📌") {
			t.Errorf("flags %v: marked session not shown marked in %q", flags, fzfInput)
		}
		wantCurrent := slices.Contains(flags, "%7")
		if strings.Contains(fzfInput, unicodeCurrent) != wantCurrent {
			t.Errorf("flags %v: current mark shown = %v, want %v in %q", flags, !wantCurrent, wantCurrent, fzfInput)
		}
		if wantCurrent {
			assertOnlySessionMarked(t, fzfInput, "a")
		}
		if out.String() != fzfInput {
			t.Errorf("flags %v: --list printed\n%q\nwant the interactive input\n%q", flags, out.String(), fzfInput)
		}
		bi := slices.Index(fzfArgv, "--bind")
		if bi < 0 || bi+1 >= len(fzfArgv) {
			t.Fatalf("flags %v: no --bind in %v", flags, fzfArgv)
		}
		wantTail := strings.Join(quoteAll(append([]string{"picker", "--list"}, flags...)), " ") + " 2>/dev/null"
		if !strings.Contains(fzfArgv[bi+1], wantTail) {
			t.Errorf("flags %v: bind %q does not reload with %q", flags, fzfArgv[bi+1], wantTail)
		}
	}
}

// assertOnlySessionMarked requires the current mark on exactly one line, and
// that line to be sessionID's. Other rows have panes of their own, so a
// comparison that ignores which pane matched would mark them too.
func assertOnlySessionMarked(t *testing.T, fzfInput, sessionID string) {
	t.Helper()
	if n := strings.Count(fzfInput, unicodeCurrent); n != 1 {
		t.Errorf("current mark appears %d times, want 1 in %q", n, fzfInput)
	}
	for _, line := range strings.Split(strings.TrimRight(fzfInput, "\n"), "\n") {
		if strings.Contains(line, unicodeCurrent) && !slices.Contains(strings.Split(line, "\t"), sessionID) {
			t.Errorf("current mark on a line that is not session %q: %q", sessionID, line)
		}
	}
}

// With no --current-pane flag the interactive picker asks the multiplexer for
// the pane itself, and hands the answer to the Tab bind's reload. Inside tmux
// TMUX_PANE answers without a subprocess; fzf returning "" ends the run before
// any later tmux call.
func TestInteractiveRunResolvesCurrentPane(t *testing.T) {
	path := filepath.Join(t.TempDir(), "q.db")
	t.Setenv("CLAUDE_QUEUE_DB", path)
	t.Setenv("CLAUDE_QUEUE_ASCII", "")
	t.Setenv("TMUX", "/tmp/fake,1,0")
	t.Setenv("TMUX_PANE", "%7")
	conn, err := db.Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	for _, q := range []string{
		"INSERT INTO sessions(session_id, tmux_pane) VALUES ('a', '%7'), ('b', '%8')",
		"INSERT INTO events(session_id, event_type, state, created_at) VALUES ('a', 'Stop', 'idle_done', unixepoch() - 3700)",
		"INSERT INTO events(session_id, event_type, state, created_at) VALUES ('b', 'Stop', 'idle_done', unixepoch() - 3700)",
	} {
		if _, err := conn.Exec(q); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	conn.Close()

	var fzfInput string
	var fzfArgv []string
	run(nil, &bytes.Buffer{}, func(c *sql.DB) {}, func(in string, args []string) (string, error) {
		fzfInput, fzfArgv = in, args
		return "", nil
	}, time.Now().Unix())
	if fzfInput == "" {
		t.Fatal("interactive path gave fzf nothing")
	}
	assertOnlySessionMarked(t, fzfInput, "a")
	bi := slices.Index(fzfArgv, "--bind")
	if bi < 0 || bi+1 >= len(fzfArgv) {
		t.Fatalf("no --bind in %v", fzfArgv)
	}
	if want := "'--current-pane' '%7'"; !strings.Contains(fzfArgv[bi+1], want) {
		t.Errorf("tab bind %q does not carry %s", fzfArgv[bi+1], want)
	}
}

func quoteAll(ss []string) []string {
	out := make([]string, len(ss))
	for i, s := range ss {
		out[i] = shellQuote(s)
	}
	return out
}
