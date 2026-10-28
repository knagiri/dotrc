package picker

import (
	"bytes"
	"database/sql"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// actionArg returns the argument of the first name(...) action in bind, ended
// at the first closing delimiter as fzf ends it (see fzfAction).
func actionArg(t *testing.T, bind, name string) string {
	t.Helper()
	i := strings.Index(bind, name)
	if i < 0 || i+len(name) >= len(bind) {
		t.Fatalf("no %s action in %q", name, bind)
	}
	open := bind[i+len(name)]
	closing := map[byte]byte{'(': ')', '[': ']', '<': '>'}[open]
	if closing == 0 {
		closing = open
	}
	rest := bind[i+len(name)+1:]
	j := strings.IndexByte(rest, closing)
	if j < 0 {
		t.Fatalf("%s action in %q is not closed", name, bind)
	}
	return rest[:j]
}

// runAs runs cmd the way fzf runs a bind command, with fzf's placeholders
// already substituted and $FZF_PROMPT set to prompt, and returns its stdout.
func runAs(t *testing.T, cmd, prompt, stdin, self string) string {
	t.Helper()
	cmd = regexp.MustCompile(`\{\d+\}`).ReplaceAllString(cmd, shellQuote("sid-123"))
	c := exec.Command("sh", "-c", cmd)
	c.Stdin = strings.NewReader(stdin)
	c.Env = append(os.Environ(), "FZF_PROMPT="+prompt, "PATH="+filepath.Dir(self)+":/usr/bin:/bin")
	out, err := c.Output()
	if err != nil {
		t.Fatalf("%s: %v", cmd, err)
	}
	return string(out)
}

// ctrl-x is done on the open list and reopen on the done list, and redraws the
// list that is showing. Each list is the control for the other: the same bind
// reaches the stub either way, so the call it gets is decided by the prompt.
func TestDoneBind_ByList(t *testing.T) {
	f := pickerFlags{ShowStale: true}
	for _, c := range []struct {
		prompt, wantRun, wantReload string
	}{
		{promptOpen, "done sid-123\n", "picker --list --show-stale\n"},
		{promptDone, "reopen sid-123\n", "picker --list --show-stale --done\n"},
	} {
		self, log := stubSelf(t, 0, "")
		bind := doneBind(self, f)
		runAs(t, actionArg(t, bind, "execute"), c.prompt, "y", self)
		if got := calls(t, log); got != c.wantRun {
			t.Errorf("prompt %q: ctrl-x ran %q, want %q", c.prompt, got, c.wantRun)
		}
		os.Remove(log)
		runAs(t, actionArg(t, bind, "+reload"), c.prompt, "", self)
		if got := calls(t, log); got != c.wantReload {
			t.Errorf("prompt %q: ctrl-x reloaded with %q, want %q", c.prompt, got, c.wantReload)
		}
	}
}

// reopen does not ask: the key that set the done takes it back.
func TestReopenScript_NoConfirm(t *testing.T) {
	self, log := stubSelf(t, 0, "")
	runAs(t, "bash -c "+shellQuote(reopenScript(self))+" _ {6}", promptDone, "", self)
	if got := calls(t, log); got != "reopen sid-123\n" {
		t.Errorf("reopen script ran %q, want one reopen call", got)
	}
}

// ctrl-r switches to the done list from the open one and back: the prompt that
// records which list shows, the header, the keys the done list turns off, and
// the reload all move together.
func TestModeBind_Toggles(t *testing.T) {
	f := pickerFlags{RepoScope: true}
	self, log := stubSelf(t, 0, "")
	bind := modeBind(self, f)
	if !strings.HasPrefix(bind, "ctrl-r:transform") {
		t.Fatalf("mode bind = %q, want ctrl-r:transform...", bind)
	}
	script := actionArg(t, bind, "transform")
	for _, c := range []struct {
		from, wantPrompt, wantHeader, wantKeys, wantReload string
	}{
		{promptOpen, promptDone, doneKeysHeader, "unbind", "picker --list --repo-scope --done\n"},
		{promptDone, promptOpen, keysHeader, "rebind", "picker --list --repo-scope\n"},
	} {
		actions := runAs(t, script, c.from, "", self)
		if got := actionArg(t, actions, "change-prompt"); got != c.wantPrompt {
			t.Errorf("from %q: prompt -> %q, want %q", c.from, got, c.wantPrompt)
		}
		if got := actionArg(t, actions, "change-header"); got != c.wantHeader {
			t.Errorf("from %q: header -> %q, want %q", c.from, got, c.wantHeader)
		}
		if got := actionArg(t, actions, c.wantKeys); got != doneListOff {
			t.Errorf("from %q: %s(%q), want %q", c.from, c.wantKeys, got, doneListOff)
		}
		os.Remove(log)
		runAs(t, actionArg(t, actions, "reload"), c.from, "", self)
		if got := calls(t, log); got != c.wantReload {
			t.Errorf("from %q: reload ran %q, want %q", c.from, got, c.wantReload)
		}
	}
	for _, k := range []string{"tab", "ctrl-t", "ctrl-e", "enter"} {
		if !strings.Contains(","+doneListOff+",", ","+k+",") {
			t.Errorf("done list leaves %s bound", k)
		}
	}
	if !strings.Contains(doneKeysHeader, "ctrl-x: reopen") || !strings.Contains(doneKeysHeader, "ctrl-r:") {
		t.Errorf("done header %q does not list ctrl-x: reopen and ctrl-r", doneKeysHeader)
	}
}

// The picker opens on the open list, whose prompt is the one the binds read.
func TestFzfArgs_PromptIsOpenList(t *testing.T) {
	var prompt string
	for _, a := range fzfArgs() {
		if p, ok := strings.CutPrefix(a, "--prompt="); ok {
			prompt = p
		}
	}
	if prompt != promptOpen {
		t.Errorf("--prompt = %q, want %q", prompt, promptOpen)
	}
}

// --list --done prints the sessions done within the retention, newest done
// first under the done icon, and nothing open; the open list has none of them.
func TestListing_DoneList(t *testing.T) {
	seedDB(t,
		"INSERT INTO sessions(session_id, done_at) VALUES ('open-1', NULL), ('done-new', unixepoch() - 60), ('done-old', unixepoch() - 3600), ('done-gc', unixepoch() - 8 * 86400)",
		"INSERT INTO events(session_id, event_type, state) VALUES ('open-1', 'Stop', 'idle_done'), ('done-new', 'Stop', 'idle_done'), ('done-old', 'Stop', 'idle_done'), ('done-gc', 'Stop', 'idle_done')",
	)
	if emoji[db.StateDone] == "" || ascii[db.StateDone] == "" {
		t.Fatalf("no icon for %q", db.StateDone)
	}
	now := time.Now().Unix()
	var ids []string
	for _, line := range strings.Split(strings.TrimRight(listOut(t, now, "--done"), "\n"), "\n") {
		sel, ok := parseSelection(line)
		if !ok {
			t.Fatalf("done list line %q does not parse", line)
		}
		ids = append(ids, sel.SessionID)
		if !strings.HasPrefix(line, emoji[db.StateDone]+"\t") {
			t.Errorf("done row without the done icon: %q", line)
		}
	}
	if strings.Join(ids, ",") != "done-new,done-old" {
		t.Errorf("done list = %v, want [done-new done-old]", ids)
	}
	if out := listOut(t, now); strings.Contains(out, "done-") || !strings.Contains(out, "open-1") {
		t.Errorf("open list = %q, want open-1 only", out)
	}
}

// With nothing open, the picker still opens when there is a done session to
// reopen, and does not when there is none.
func TestRun_EmptyOpenListOpensForDone(t *testing.T) {
	for _, c := range []struct {
		doneAt string
		want   bool
	}{
		{"unixepoch() - 60", true},
		{"unixepoch() - 8 * 86400", false},
	} {
		seedDB(t,
			"INSERT INTO sessions(session_id, done_at) VALUES ('d', "+c.doneAt+")",
			"INSERT INTO events(session_id, event_type, state) VALUES ('d', 'Stop', 'idle_done')",
		)
		var opened bool
		var input string
		run(nil, &bytes.Buffer{}, func(*sql.DB) {}, func(in string, _ []string) (string, error) {
			opened, input = true, in
			return "", nil
		}, time.Now().Unix())
		if opened != c.want {
			t.Errorf("done_at %s: fzf opened = %v, want %v", c.doneAt, opened, c.want)
		}
		if input != "" {
			t.Errorf("fzf given %q, want the empty open list", input)
		}
	}
}

// A pick that reaches the picker from the done list is refused.
func TestIsDone(t *testing.T) {
	path := seedDB(t, "INSERT INTO sessions(session_id, done_at) VALUES ('o', NULL), ('d', unixepoch())")
	conn, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if isDone(conn, "o") || !isDone(conn, "d") || isDone(conn, "missing") {
		t.Errorf("isDone(o, d, missing) = %v, %v, %v; want false, true, false", isDone(conn, "o"), isDone(conn, "d"), isDone(conn, "missing"))
	}
}
