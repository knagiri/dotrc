package picker

import (
	"database/sql"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// The annotation column carries the pin note and the memo, and sits behind the
// hidden columns so none of them moves.
func TestFormatLine_AnnotationColumn(t *testing.T) {
	ns := func(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }
	cases := []struct {
		name             string
		marked           bool
		memo, note       string
		ascii            bool
		want             string
		wantMemo, wantPN string
	}{
		{name: "memo", memo: "fix ci", want: "📝 fix ci", wantMemo: "fix ci"},
		{name: "note", marked: true, note: "review", want: "📌 review", wantPN: "review"},
		{name: "both", marked: true, memo: "fix ci", note: "review", want: "📌 review 📝 fix ci", wantMemo: "fix ci", wantPN: "review"},
		{name: "both ascii", marked: true, memo: "m", note: "n", ascii: true, want: "[P] n [M] m", wantMemo: "m", wantPN: "n"},
		{name: "none", want: ""},
		// A note left on an unpinned row is not shown: the pin is what it is a
		// note on.
		{name: "note without pin", note: "stale", want: ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			row := db.Row{
				SessionID:      "sid",
				TmuxPane:       ns("%4"),
				Cwd:            ns("/w/a"),
				TranscriptPath: ns("/t/a.jsonl"),
				ConfigDir:      ns("/cfg/a"),
				EffectiveState: "working",
				CreatedAt:      nowMinus(60),
				Marked:         c.marked,
				Memo:           ns(c.memo),
				PinNote:        ns(c.note),
			}
			line := FormatLine(row, "title", "wt", nowUnix(), c.ascii)
			fields := strings.Split(line, "\t")
			if len(fields) != colCount {
				t.Fatalf("got %d columns, want %d", len(fields), colCount)
			}
			if fields[colAnnotation] != c.want {
				t.Errorf("annotation = %q, want %q", fields[colAnnotation], c.want)
			}
			if fields[colMemo] != c.wantMemo || fields[colPinNote] != c.wantPN {
				t.Errorf("raw memo, note = %q, %q; want %q, %q", fields[colMemo], fields[colPinNote], c.wantMemo, c.wantPN)
			}
			sel, ok := parseSelection(line)
			want := selection{SessionID: "sid", Pane: "%4", Cwd: "/w/a", Transcript: "/t/a.jsonl", ConfigDir: "/cfg/a"}
			if !ok || sel != want {
				t.Errorf("parseSelection = %+v, %v; want %+v", sel, ok, want)
			}
		})
	}
}

// Each edit key passes the session id and the raw text it edits as {N}s that
// land on those columns of a rendered line, and the header lists every key.
func TestFzfArgs_Binds(t *testing.T) {
	f := pickerFlags{ShowStale: true}
	row := db.Row{
		SessionID: "sid-123", EffectiveState: "idle_done", CreatedAt: nowMinus(60), Marked: true,
		Memo: sql.NullString{String: "the memo", Valid: true}, PinNote: sql.NullString{String: "the note", Valid: true},
	}
	fields := strings.Split(FormatLine(row, "t", "w", nowUnix(), false), "\t")
	field := func(n string) string {
		i, _ := strconv.Atoi(n)
		if i < 1 || i > len(fields) {
			return "<out of range>"
		}
		return fields[i-1]
	}
	for _, c := range []struct {
		key, bind, sub string
		want           []string
	}{
		{"ctrl-e", memoBind("/opt/x/claude-queue", f), "memo --session", []string{"sid-123", "the memo"}},
		{"ctrl-t", pinNoteBind("/opt/x/claude-queue", f), "pin --session", []string{"sid-123", "the note"}},
		{"ctrl-x", doneBind("/opt/x/claude-queue", f), "done", []string{"sid-123"}},
	} {
		if !strings.HasPrefix(c.bind, c.key+":execute") {
			t.Errorf("%s bind = %q", c.key, c.bind)
		}
		if strings.HasPrefix(c.bind, c.key+":execute-silent") {
			t.Errorf("%s bind runs silently, so it cannot ask or show a failure", c.key)
		}
		if !strings.Contains(c.bind, c.sub) {
			t.Errorf("%s bind %q does not run %q", c.key, c.bind, c.sub)
		}
		m := regexp.MustCompile(` _((?: \{\d+\})+)`).FindStringSubmatch(c.bind)
		if m == nil {
			t.Fatalf("%s bind %q passes no {N}", c.key, c.bind)
		}
		var got []string
		for _, n := range regexp.MustCompile(`\d+`).FindAllString(m[1], -1) {
			got = append(got, field(n))
		}
		if !slices.Equal(got, c.want) {
			t.Errorf("%s passes %v, want %v", c.key, got, c.want)
		}
		// ctrl-x reloads whichever list is showing, so its reload is a bash if
		// that quotes the flags once more; TestDoneBind_ByList runs it.
		if c.key != "ctrl-x" && !strings.Contains(c.bind, "'picker' '--list' '--show-stale'") {
			t.Errorf("%s bind does not reload with the same flags", c.key)
		}
	}

	if b := memoBind("/opt/x/claude-queue", f); !strings.Contains(b, `-- "$line"`) {
		t.Errorf("ctrl-e bind %q must pass -- before the text so a leading dash is not parsed as a flag", b)
	}

	args := fzfArgs()
	i := slices.IndexFunc(args, func(a string) bool { return strings.HasPrefix(a, "--header=") })
	if i < 0 {
		t.Fatalf("fzfArgs = %v, want a --header", args)
	}
	for _, k := range []string{"tab", "ctrl-e", "ctrl-t", "ctrl-x", "ctrl-r"} {
		if !strings.Contains(args[i], k+":") {
			t.Errorf("header %q does not list %s", args[i], k)
		}
	}
}

// stubSelf writes a claude-queue stand-in that records its argv and exits
// with code, printing stderr to stderr. It forwards nothing: the scripts are
// handed its absolute path as self, so no real claude-queue is reachable.
func stubSelf(t *testing.T, code int, stderr string) (self, log string) {
	t.Helper()
	dir := t.TempDir()
	self = filepath.Join(dir, "claude-queue")
	log = filepath.Join(dir, "calls")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >>" + shellQuote(log) + "\nprintf '%s' " + shellQuote(stderr) + " >&2\nexit " + strconv.Itoa(code) + "\n"
	if err := os.WriteFile(self, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return self, log
}

func runDoneScript(t *testing.T, self, stdin string) string {
	t.Helper()
	cmd := exec.Command("bash", "-c", doneScript(self), "_", "sid-123")
	cmd.Stdin = strings.NewReader(stdin)
	// The real claude-queue must not be on PATH either, should the script ever
	// reach for it by name.
	cmd.Env = append(os.Environ(), "PATH="+filepath.Dir(self)+":/usr/bin:/bin")
	out, _ := cmd.CombinedOutput()
	return string(out)
}

func calls(t *testing.T, log string) string {
	t.Helper()
	b, err := os.ReadFile(log)
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// ctrl-x marks the session done only on y. The y case is the control: it shows
// the stub is what the script reaches, so its silence on the others means
// something.
func TestDoneConfirmScript_DefaultNo(t *testing.T) {
	self, log := stubSelf(t, 0, "")
	out := runDoneScript(t, self, "y")
	if got := calls(t, log); got != "done sid-123\n" {
		t.Fatalf("on y the stub got %q, want one done call (output %q)", got, out)
	}
	if !strings.Contains(out, "[y/N]") {
		t.Errorf("no confirmation prompt in %q", out)
	}
	for _, in := range []string{"n", "", "\n", "x"} {
		self, log := stubSelf(t, 0, "")
		runDoneScript(t, self, in)
		if got := calls(t, log); got != "" {
			t.Errorf("stdin %q reached claude-queue: %q", in, got)
		}
	}
}

// A failed done shows why instead of vanishing under the redraw.
func TestDoneConfirmScript_ShowsFailure(t *testing.T) {
	self, _ := stubSelf(t, 1, "done: no session in the ledger starts with x")
	out := runDoneScript(t, self, "y")
	if !strings.Contains(out, "no session in the ledger starts with x") {
		t.Errorf("failure not shown: %q", out)
	}
}
