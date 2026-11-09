package picker

import (
	"os/exec"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

const (
	dimOn  = "\x1b[2m"
	dimOff = "\x1b[0m"
)

// The refs column is appended behind every existing one, so the hidden columns
// parseSelection reads keep their positions; dimRefs wraps it in ANSI dim.
func TestFormatLine_RefsColumn(t *testing.T) {
	row := db.Row{SessionID: "sid-123", EffectiveState: "idle_done", CreatedAt: nowMinus(60)}
	plain := strings.Split(FormatLine(row, "t", "w", "#42 feat/foo", false, nowUnix(), false), "\t")
	if len(plain) != colCount || plain[colRefs] != "#42 feat/foo" {
		t.Fatalf("fields = %q (len %d), want %d with refs at %d", plain, len(plain), colCount, colRefs)
	}
	if plain[colSessionID] != "sid-123" {
		t.Errorf("session id moved: %q", plain)
	}
	dim := strings.Split(FormatLine(row, "t", "w", "#42 feat/foo", true, nowUnix(), false), "\t")
	if dim[colRefs] != dimOn+"#42 feat/foo"+dimOff {
		t.Errorf("dim refs = %q", dim[colRefs])
	}
	// No refs, nothing to dim: an escape alone would still be a stray match target.
	if got := strings.Split(FormatLine(row, "t", "w", "", true, nowUnix(), false), "\t")[colRefs]; got != "" {
		t.Errorf("empty dim refs = %q, want empty", got)
	}
}

// The tree's refs land on every row of it: plain on the root, dim on the
// delegates; a session outside any tree gets none.
func TestListing_TreeRefsOnEveryRow(t *testing.T) {
	seedDB(t,
		"INSERT INTO sessions(session_id) VALUES ('aaaaaaaa-0000'), ('bbbbbbbb-0000'), ('eeeeeeee-0000')",
		"INSERT INTO events(session_id, event_type, state) VALUES ('aaaaaaaa-0000', 'Stop', 'idle_done'), ('bbbbbbbb-0000', 'Stop', 'idle_done'), ('eeeeeeee-0000', 'Stop', 'idle_done')",
		"INSERT INTO session_links(child_short, parent_session_id, repo, branch, pr) VALUES ('bbbbbbbb', 'aaaaaaaa-0000', 'example-org/example-repo', 'feat/foo', 142)",
	)
	got := map[string]string{}
	for _, line := range strings.Split(strings.TrimRight(listOut(t, time.Now().Unix(), "--show-working"), "\n"), "\n") {
		f := strings.Split(line, "\t")
		got[f[colSessionID]] = f[colRefs]
	}
	want := map[string]string{
		"aaaaaaaa-0000": "#142 feat/foo",
		"bbbbbbbb-0000": dimOn + "#142 feat/foo" + dimOff,
		"eeeeeeee-0000": "",
	}
	for id, w := range want {
		if g, ok := got[id]; !ok || g != w {
			t.Errorf("%s refs = %q (listed %v), want %q", id, g, ok, w)
		}
	}
}

// The done list carries the same refs, undimmed: it is flat, so no row there
// repeats another's.
func TestDoneListing_TreeRefsUndimmed(t *testing.T) {
	seedDB(t,
		"INSERT INTO sessions(session_id) VALUES ('aaaaaaaa-0000')",
		"INSERT INTO sessions(session_id, terminated_at, done_at) VALUES ('bbbbbbbb-0000', unixepoch() - 10, unixepoch() - 10)",
		"INSERT INTO events(session_id, event_type, state) VALUES ('aaaaaaaa-0000', 'Stop', 'idle_done'), ('bbbbbbbb-0000', 'SessionEnd', 'ended')",
		"INSERT INTO session_links(child_short, parent_session_id, repo, branch, pr) VALUES ('bbbbbbbb', 'aaaaaaaa-0000', 'example-org/example-repo', 'feat/foo', 142)",
	)
	out := strings.TrimRight(listOut(t, time.Now().Unix(), "--done"), "\n")
	f := strings.Split(out, "\t")
	if len(f) != colCount || f[colSessionID] != "bbbbbbbb-0000" || f[colRefs] != "#142 feat/foo" {
		t.Errorf("done listing = %q", out)
	}
}

func TestFzfArgs_SearchColumns(t *testing.T) {
	if got, want := searchColumns(), "2,3,6,7"; got != want {
		t.Errorf("searchColumns = %q, want %q", got, want)
	}
	args := fzfArgs("")
	for _, want := range []string{"--ansi", "--nth=" + searchColumns()} {
		if !slices.Contains(args, want) {
			t.Errorf("fzfArgs = %v, want it to carry %s", args, want)
		}
	}
}

// What fzf actually matches against, through the real binary: a word in the
// summary must find nothing, a PR number must find the row carrying it -- the
// --nth numbering after --with-nth is the thing that would silently be off.
func TestFzfFilter_SearchColumns(t *testing.T) {
	if _, err := exec.LookPath("fzf"); err != nil {
		t.Skip("fzf not on PATH")
	}
	withRefs := db.Row{SessionID: "sid-refs", EffectiveState: "idle_done", CreatedAt: nowMinus(60)}
	// An unknown state is summarised as itself: a summary that says zzsummary.
	withSummary := db.Row{SessionID: "sid-summary", EffectiveState: "zzsummary", CreatedAt: nowMinus(60)}
	input := FormatLine(withSummary, "t1", "w1", "", false, nowUnix(), false) + "\n" +
		FormatLine(withRefs, "t2", "w2", "#142 feat/foo", true, nowUnix(), false) + "\n"
	if !strings.Contains(strings.Split(input, "\n")[0], "zzsummary") {
		t.Fatalf("fixture: the summary does not carry zzsummary:\n%q", input)
	}
	var keep []string
	for _, a := range fzfArgs() {
		if strings.HasPrefix(a, "--delimiter") || strings.HasPrefix(a, "--with-nth") ||
			strings.HasPrefix(a, "--nth") || a == "--ansi" {
			keep = append(keep, a)
		}
	}
	filter := func(q string) []string {
		cmd := exec.Command("fzf", append(keep, "--filter="+q)...)
		cmd.Stdin = strings.NewReader(input)
		cmd.Env = append(cmd.Environ(), "FZF_DEFAULT_OPTS=")
		out, _ := cmd.Output() // exit 1 is "no match"
		var ids []string
		for _, l := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
			if f := strings.Split(l, "\t"); len(f) > colSessionID {
				ids = append(ids, f[colSessionID])
			}
		}
		return ids
	}
	if got := filter("zzsummary"); len(got) != 0 {
		t.Errorf("summary text matched %v", got)
	}
	if got := filter("'#142"); !slices.Equal(got, []string{"sid-refs"}) {
		t.Errorf("'#142 matched %v, want [sid-refs]", got)
	}
	if got := filter("'feat/foo"); !slices.Equal(got, []string{"sid-refs"}) {
		t.Errorf("'feat/foo matched %v, want [sid-refs]", got)
	}
	if got := filter("'t1"); !slices.Equal(got, []string{"sid-summary"}) {
		t.Errorf("title t1 matched %v, want [sid-summary]", got)
	}
}
