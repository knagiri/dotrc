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

// A marked row swaps its icon and nothing else; stale included, because a
// parked session that went stale is still one the user meant to return to.
func TestFormatLine_MarkedIcon(t *testing.T) {
	for _, tc := range []struct {
		state  string
		marked bool
		ascii  bool
		want   string
	}{
		{"idle_done", true, false, "📌"},
		{"idle_done", true, true, "[P]"},
		{"stale", true, false, "📌"},
		{"stale", true, true, "[P]"},
		{"stale", false, false, "🧟"},
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
	bind := tabBind("/a b/it's(1)/claude-queue", pickerFlags{ShowStale: true})
	q := `'/a b/it'\''s(1)/claude-queue'`
	if !strings.Contains(bind, q+" mark ") || !strings.Contains(bind, q+" 'picker' '--list' '--show-stale'") {
		t.Errorf("binary path not shell-quoted in %q", bind)
	}
	// A ')' in the path must not end the action argument early.
	if strings.Contains(bind, "execute-silent(") || strings.Contains(bind, "reload(") {
		t.Errorf("bind %q used () around an argument containing ')'", bind)
	}
}

func TestListArgs(t *testing.T) {
	got := pickerFlags{ShowWorking: true, ShowStale: true, ShowResumable: true, RepoScope: true}.listArgs()
	want := []string{"picker", "--list", "--show-working", "--show-stale", "--show-resumable", "--repo-scope"}
	if !slices.Equal(got, want) {
		t.Errorf("listArgs = %v, want %v", got, want)
	}
	if got := (pickerFlags{}).listArgs(); !slices.Equal(got, []string{"picker", "--list"}) {
		t.Errorf("listArgs() = %v", got)
	}
}

// --list is what Tab reloads the popup with, so it must print exactly what the
// interactive picker handed fzf for the same flags -- and the interactive
// picker's bind must ask --list for those same flags.
func TestListModeMatchesInteractiveInput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "q.db")
	t.Setenv("CLAUDE_QUEUE_DB", path)
	t.Setenv("CLAUDE_QUEUE_ASCII", "")
	conn, err := db.Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	for _, q := range []string{
		"INSERT INTO sessions(session_id) VALUES ('a'), ('b'), ('c')",
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

	for _, flags := range [][]string{nil, {"--show-working"}, {"--show-working", "--show-stale"}} {
		var fzfInput string
		var fzfArgv []string
		run(flags, &bytes.Buffer{}, func(c *sql.DB) {}, func(in string, args []string) (string, error) {
			fzfInput, fzfArgv = in, args
			return "", nil
		})
		var out bytes.Buffer
		run(append([]string{"--list"}, flags...), &out, func(c *sql.DB) { t.Error("--list ran the reconcile sweep") }, func(string, []string) (string, error) {
			t.Error("--list started fzf")
			return "", nil
		})
		if fzfInput == "" {
			t.Fatalf("flags %v: interactive path gave fzf nothing", flags)
		}
		if !strings.Contains(fzfInput, "📌") {
			t.Errorf("flags %v: marked session not shown marked in %q", flags, fzfInput)
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

func quoteAll(ss []string) []string {
	out := make([]string, len(ss))
	for i, s := range ss {
		out[i] = shellQuote(s)
	}
	return out
}
