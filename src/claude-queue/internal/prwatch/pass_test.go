package prwatch

import (
	"bytes"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/hibernate"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

const (
	sid   = "pinnedaa-1111-2222"
	pr    = "example-org/example-repo#12"
	cfg   = "/home/x/.claude-other"
	stray = 1 << 30 // a pid nothing runs as
)

var now = time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)

// world is a stubbed Deps that records every effect a delivery can have.
type world struct {
	activity Activity
	pollErr  error
	agents   []roster.Agent
	latest   string
	visible  bool
	children int
	runErr   error

	polled  []string
	ran     [][]string
	ranEnv  [][]string
	ended   []int
	killed  []string
	stopped []string
}

func (w *world) deps() Deps {
	return Deps{
		Poll: func(p, dir string) (Activity, error) {
			w.polled = append(w.polled, p+"@"+dir)
			return w.activity, w.pollErr
		},
		Hibernate: hibernate.Deps{
			FindPane:       func(int) (string, bool) { return "%7", true },
			WindowOf:       func(string) (string, error) { return "@3", nil },
			VisibleWindows: func() (map[string]bool, error) { return map[string]bool{"@3": w.visible}, nil },
			End: func(pid int, _, _ string) error {
				w.ended = append(w.ended, pid)
				return nil
			},
			PaneExists: func(string) bool { return true },
			KillPane: func(p string) error {
				w.killed = append(w.killed, p)
				return nil
			},
			Stop: func(_, id string) error {
				w.stopped = append(w.stopped, id)
				return nil
			},
			List: func(string) ([]roster.Agent, error) { return w.agents, nil },
			LatestEvent: func(string) (string, int64, bool, error) {
				return w.latest, now.Unix() - 600, w.latest != "", nil
			},
		},
		RunningDelegates: func() (map[string]int, error) { return map[string]int{sid: w.children}, nil },
		IsFile:           func(p string) bool { _, err := os.Stat(p); return err == nil },
		IsDir:            func(p string) bool { fi, err := os.Stat(p); return err == nil && fi.IsDir() },
		SessionName:      func(string) string { return "example-repo_feature" },
		WindowName:       func(string, string) string { return "fix the thing" },
		SessionExists:    func(string) bool { return false },
		HaveSystemdRun:   func() bool { return true },
		Run: func(argv, env []string, _ string) error {
			w.ran = append(w.ran, argv)
			w.ranEnv = append(w.ranEnv, env)
			return w.runErr
		},
	}
}

// pin is a gone interactive session pinned on pr, with a real cwd and
// transcript so the resume preconditions hold.
func pin(t *testing.T) db.PRPin {
	t.Helper()
	dir := t.TempDir()
	tr := filepath.Join(dir, "t.jsonl")
	if err := os.WriteFile(tr, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return db.PRPin{SessionID: sid, PR: pr, Cwd: dir, TranscriptPath: tr, ConfigDir: cfg, Kind: db.KindInteractive, Gone: true}
}

// Every effect of a delivery -- stopping a running session and launching the
// resume -- lands on a world stub, none on a real tmux, claude or systemd-run.
func TestDeliver_StubsCatchEveryEffect(t *testing.T) {
	for _, kind := range []string{roster.KindInteractive, roster.KindBackground} {
		w := &world{latest: "idle_done", agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: kind, Status: roster.StatusIdle}}}
		p := pin(t)
		p.Gone = false
		if err := Deliver(p, "m", w.deps()); err != nil {
			t.Fatalf("%v: %v", kind, err)
		}
		if len(w.ran) != 1 || len(w.ended)+len(w.stopped) != 1 {
			t.Errorf("%v: effects not all captured: ran %q ended %v stopped %v", kind, w.ran, w.ended, w.stopped)
		}
	}
}

func TestDeliver_GoneInteractiveOpensWindow(t *testing.T) {
	w := &world{}
	if err := Deliver(pin(t), "PR has news", w.deps()); err != nil {
		t.Fatal(err)
	}
	if len(w.ran) != 1 {
		t.Fatalf("ran %q", w.ran)
	}
	argv := w.ran[0]
	if !slices.Equal(argv[:6], []string{"systemd-run", "--user", "--scope", "--quiet", "--collect", "--"}) || argv[6] != "tmux" {
		t.Errorf("not launched through systemd-run: %q", argv)
	}
	if !slices.Contains(argv, "new-session") || !slices.Contains(argv, "-d") || !slices.Contains(argv, "example-repo_feature") {
		t.Errorf("not a detached session in the worktree's tmux session: %q", argv)
	}
	if !slices.Contains(argv, "CLAUDE_CONFIG_DIR="+cfg) {
		t.Errorf("the window does not run under the recorded config dir: %q", argv)
	}
	cmd := argv[len(argv)-1]
	if !strings.Contains(cmd, "'claude' '--resume' '"+sid+"' 'PR has news'") {
		t.Errorf("window command = %q", cmd)
	}
	if len(w.ended)+len(w.stopped) != 0 {
		t.Errorf("a gone session was stopped: ended %v, stopped %v", w.ended, w.stopped)
	}
}

// An existing tmux session gets a new window, detached so a person attached
// to that session keeps looking at what they were looking at.
func TestDeliver_ExistingSessionNewWindowDetached(t *testing.T) {
	w := &world{}
	d := w.deps()
	d.SessionExists = func(string) bool { return true }
	d.HaveSystemdRun = func() bool { return false }
	if err := Deliver(pin(t), "m", d); err != nil {
		t.Fatal(err)
	}
	if argv := w.ran[0]; argv[0] != "tmux" || argv[1] != "new-window" || argv[2] != "-d" {
		t.Errorf("argv = %q", argv)
	}
	// -S with -d makes tmux do nothing when a same-named window exists.
	if slices.Contains(w.ran[0], "-S") {
		t.Errorf("-S would turn a name collision into a silent no-op: %q", w.ran[0])
	}
}

func TestDeliver_GoneBackground(t *testing.T) {
	w := &world{}
	p := pin(t)
	p.Kind = db.KindBackground
	if err := Deliver(p, "m", w.deps()); err != nil {
		t.Fatal(err)
	}
	if want := []string{"systemd-run", "--user", "--scope", "--quiet", "--collect", "--", "claude", "--bg", "--resume", sid, "m"}; !slices.Equal(w.ran[0], want) {
		t.Errorf("argv = %q", w.ran[0])
	}
	if !slices.Contains(w.ranEnv[0], "CLAUDE_CONFIG_DIR="+cfg) {
		t.Errorf("env lacks the config dir")
	}
}

// A running interactive session is stopped (process ended, pane killed) and
// only then resumed in a new tmux window.
func TestDeliver_RunningInteractiveStoppedThenResumed(t *testing.T) {
	w := &world{latest: "idle_done", agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: roster.KindInteractive, Status: roster.StatusIdle}}}
	var order []string
	d := w.deps()
	end, kill, run := d.Hibernate.End, d.Hibernate.KillPane, d.Run
	d.Hibernate.End = func(pid int, a, b string) error { order = append(order, "end"); return end(pid, a, b) }
	d.Hibernate.KillPane = func(pn string) error { order = append(order, "kill"); return kill(pn) }
	d.Run = func(a, e []string, dir string) error { order = append(order, "run"); return run(a, e, dir) }
	p := pin(t)
	p.Gone = false
	if err := Deliver(p, "m", d); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(w.ended, []int{stray}) || !slices.Equal(w.killed, []string{"%7"}) || len(w.stopped) != 0 {
		t.Errorf("ended %v killed %v stopped %v", w.ended, w.killed, w.stopped)
	}
	if len(w.ran) != 1 || !slices.Contains(w.ran[0], "tmux") {
		t.Fatalf("ran %q", w.ran)
	}
	if !slices.Equal(order, []string{"end", "kill", "run"}) {
		t.Errorf("order = %v, the resume must come after the stop", order)
	}
}

// The listing decides how a running session is resumed, not the ledger's Kind:
// one recorded as interactive but listed as background is stopped with
// `claude stop` and resumed with `claude --bg`, with no tmux window.
func TestDeliver_RunningKindFromListing(t *testing.T) {
	w := &world{latest: "idle_done", agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: roster.KindBackground, Status: roster.StatusIdle}}}
	p := pin(t)
	p.Gone = false
	p.Kind = db.KindInteractive
	if err := Deliver(p, "m", w.deps()); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(w.stopped, []string{sid}) || len(w.ended) != 0 {
		t.Errorf("stopped %v ended %v", w.stopped, w.ended)
	}
	want := []string{"systemd-run", "--user", "--scope", "--quiet", "--collect", "--", "claude", "--bg", "--resume", sid, "m"}
	if len(w.ran) != 1 || !slices.Equal(w.ran[0], want) {
		t.Errorf("ran %q", w.ran)
	}
}

func TestDeliver_VisibleSkipped(t *testing.T) {
	w := &world{visible: true, latest: "idle_done", agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: roster.KindInteractive, Status: roster.StatusIdle}}}
	p := pin(t)
	p.Gone = false
	err := Deliver(p, "m", w.deps())
	if !hibernate.IsSkip(err) || !strings.Contains(err.Error(), "on screen") {
		t.Fatalf("err = %v", err)
	}
	if len(w.ended)+len(w.ran) != 0 {
		t.Errorf("acted on a session on screen: ended %v, ran %q", w.ended, w.ran)
	}
}

func TestDeliver_RunningBusySkipped(t *testing.T) {
	w := &world{latest: "working", agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: roster.KindInteractive, Status: "busy"}}}
	p := pin(t)
	p.Gone = false
	if err := Deliver(p, "m", w.deps()); !hibernate.IsSkip(err) {
		t.Fatalf("err = %v", err)
	}
	if len(w.ended)+len(w.ran) != 0 {
		t.Errorf("interrupted a session in a turn")
	}
}

func TestDeliver_RunningChildSkipped(t *testing.T) {
	w := &world{children: 1, latest: "idle_done", agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: roster.KindInteractive, Status: roster.StatusIdle}}}
	p := pin(t)
	p.Gone = false
	if err := Deliver(p, "m", w.deps()); !hibernate.IsSkip(err) || !strings.Contains(err.Error(), "delegate") {
		t.Fatalf("err = %v", err)
	}
	if len(w.ended)+len(w.ran) != 0 {
		t.Errorf("acted on a session with a running delegate")
	}
}

// A session whose working directory is gone is skipped before anything is stopped, so it is not left gone for a resume that cannot work.
func TestDeliver_MissingCwdSkipped(t *testing.T) {
	w := &world{latest: "idle_done", agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: roster.KindInteractive, Status: roster.StatusIdle}}}
	p := pin(t)
	p.Gone = false
	p.Cwd = filepath.Join(p.Cwd, "reaped")
	if err := Deliver(p, "m", w.deps()); !hibernate.IsSkip(err) || !strings.Contains(err.Error(), "working directory") {
		t.Fatalf("err = %v", err)
	}
	if len(w.ended)+len(w.ran) != 0 {
		t.Errorf("stopped a session it cannot resume: ended %v, ran %q", w.ended, w.ran)
	}
}

func TestMessage_Activity(t *testing.T) {
	m := Message(pr, Activity{State: StateOpen}, []Event{
		{Kind: KindReview, Author: "example-user", ReviewState: "CHANGES_REQUESTED", Summary: "rename this"},
		{Kind: KindComment, Author: "example-bot[bot]", Summary: "nit"},
	})
	for _, want := range []string{"PR " + pr + " に新しい活動があります", "- example-user: changes_requested rename this", "- example-bot[bot]: comment nit", "delegate-to-worktree"} {
		if !strings.Contains(m, want) {
			t.Errorf("message lacks %q:\n%s", want, m)
		}
	}
}

func TestMessage_MergedAndClosed(t *testing.T) {
	if m := Message(pr, Activity{State: StateMerged}, nil); !strings.Contains(m, "merge されました") {
		t.Errorf("merged: %s", m)
	}
	if m := Message(pr, Activity{State: StateClosed}, nil); !strings.Contains(m, "merge されずに close") {
		t.Errorf("closed: %s", m)
	}
}

// ledger holds one gone interactive session pinned on pr with its cursor at
// 10:00, and returns it with the pin's cwd.
func ledger(t *testing.T, id string) *sql.DB {
	t.Helper()
	conn, err := db.Open(filepath.Join(t.TempDir(), "q.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	p := pin(t)
	if _, err := conn.Exec("INSERT INTO sessions(session_id, cwd, transcript_path, config_dir, kind, terminated_at) VALUES (?, ?, ?, ?, 'interactive', 1)",
		id, p.Cwd, p.TranscriptPath, cfg); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec("INSERT INTO events(session_id, event_type, state) VALUES (?, 'Stop', 'idle_done')", id); err != nil {
		t.Fatal(err)
	}
	if err := db.SetPinPR(conn, id, pr, at("10:00")); err != nil {
		t.Fatal(err)
	}
	return conn
}

func pinState(t *testing.T, conn *sql.DB, id string) (pinned bool, cursor sql.NullString, seen sql.NullInt64) {
	t.Helper()
	if err := conn.QueryRow("SELECT waiting_event_id IS NOT NULL, pin_cursor, pin_seen_at FROM sessions WHERE session_id = ?", id).Scan(&pinned, &cursor, &seen); err != nil {
		t.Fatal(err)
	}
	return
}

var news = Activity{State: StateOpen, Events: []Event{
	{Kind: KindComment, Author: "example-user", At: at("09:00"), Summary: "old"},
	{Kind: KindComment, Author: "example-user", At: at("10:30"), Summary: "new one"},
	{Kind: KindReview, Author: "example-bot[bot]", At: at("10:40"), ReviewState: "COMMENTED", Summary: "new two"},
}}

// The first pass that sees new activity only records it; the next one, a tick
// later, delivers it all at once and moves the cursor to the newest event.
func TestPass_DebounceOneTick(t *testing.T) {
	conn := ledger(t, sid)
	w := &world{activity: news}
	var out bytes.Buffer
	if got := Pass(conn, now, DefaultDebounce, w.deps(), &out); len(got) != 0 || len(w.ran) != 0 {
		t.Fatalf("first pass delivered: resumed %v, ran %q\n%s", got, w.ran, &out)
	}
	if _, _, seen := pinState(t, conn, sid); seen.Int64 != now.Unix() {
		t.Fatalf("pin_seen_at = %v", seen)
	}
	got := Pass(conn, now.Add(3*time.Minute), DefaultDebounce, w.deps(), &out)
	if !got[sid] || len(w.ran) != 1 {
		t.Fatalf("second pass: resumed %v, ran %q\n%s", got, w.ran, &out)
	}
	cmd := w.ran[0][len(w.ran[0])-1]
	if !strings.Contains(cmd, "new one") || !strings.Contains(cmd, "new two") || strings.Contains(cmd, "old") {
		t.Errorf("delivered message = %q", cmd)
	}
	pinned, cursor, seen := pinState(t, conn, sid)
	if !pinned || cursor.String != "2026-10-26T10:40:00Z" || seen.Valid {
		t.Errorf("after delivery: pinned=%v cursor=%v seen=%v", pinned, cursor, seen)
	}
	// Nothing newer: the third pass delivers nothing.
	Pass(conn, now.Add(6*time.Minute), DefaultDebounce, w.deps(), &out)
	if len(w.ran) != 1 {
		t.Errorf("delivered again: %q", w.ran)
	}
}

// A failed or skipped delivery leaves the cursor where it was,
// so the next pass retries with the same activity, and a successful one is not
// repeated.
func TestPass_CursorAdvancesOnlyOnSuccess(t *testing.T) {
	conn := ledger(t, sid)
	if err := db.SetPRSeen(conn, sid, pr, now.Unix()-600); err != nil {
		t.Fatal(err)
	}
	w := &world{activity: news, runErr: errors.New("tmux: no server")}
	var out bytes.Buffer
	if got := Pass(conn, now, DefaultDebounce, w.deps(), &out); len(got) != 0 {
		t.Fatalf("a failed delivery reported as resumed: %v", got)
	}
	if _, cursor, seen := pinState(t, conn, sid); cursor.String != "2026-10-26T10:00:00Z" || !seen.Valid {
		t.Fatalf("failed delivery moved the pin: cursor=%v seen=%v", cursor, seen)
	}
	if !strings.Contains(out.String(), "pr-watch: failed pinnedaa") {
		t.Errorf("failure not reported:\n%s", &out)
	}
	w.runErr = nil
	Pass(conn, now.Add(3*time.Minute), DefaultDebounce, w.deps(), &out)
	Pass(conn, now.Add(6*time.Minute), DefaultDebounce, w.deps(), &out)
	if len(w.ran) != 2 {
		t.Errorf("want the failed attempt and one retry, ran %d times:\n%s", len(w.ran), &out)
	}
}

func TestPass_MergedUnpins(t *testing.T) {
	conn := ledger(t, sid)
	w := &world{activity: Activity{State: StateMerged, Events: news.Events}}
	var out bytes.Buffer
	if got := Pass(conn, now, DefaultDebounce, w.deps(), &out); !got[sid] {
		t.Fatalf("merge not delivered at once:\n%s", &out)
	}
	if cmd := w.ran[0][len(w.ran[0])-1]; !strings.Contains(cmd, "merge されました") {
		t.Errorf("message = %q", cmd)
	}
	if pinned, _, _ := pinState(t, conn, sid); pinned {
		t.Error("still pinned after the merge was delivered")
	}
	pins, err := db.PRPins(conn)
	if err != nil || len(pins) != 0 {
		t.Errorf("PRPins after merge = %v, %v", pins, err)
	}
}

// A session that is done (not open work) is never polled or woken.
func TestPass_DoneSessionIgnored(t *testing.T) {
	conn := ledger(t, sid)
	if _, err := db.MarkDone(conn, sid, now.Unix()); err != nil {
		t.Fatal(err)
	}
	w := &world{activity: Activity{State: StateMerged}}
	Pass(conn, now, DefaultDebounce, w.deps(), &bytes.Buffer{})
	if len(w.polled)+len(w.ran) != 0 {
		t.Errorf("a done session was watched: polled %v, ran %q", w.polled, w.ran)
	}
}

// One pin's gh failure is reported and the
// other pins are still watched.
func TestPass_GhErrorSkipsPin(t *testing.T) {
	conn := ledger(t, sid)
	other := "otherbbb-3333"
	p := pin(t)
	if _, err := conn.Exec("INSERT INTO sessions(session_id, cwd, transcript_path, config_dir, kind, terminated_at) VALUES (?, ?, ?, ?, 'interactive', 1)",
		other, p.Cwd, p.TranscriptPath, cfg); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec("INSERT INTO events(session_id, event_type, state) VALUES (?, 'Stop', 'idle_done')", other); err != nil {
		t.Fatal(err)
	}
	if err := db.SetPinPR(conn, other, "example-org/example-repo#13", at("10:00")); err != nil {
		t.Fatal(err)
	}
	w := &world{}
	d := w.deps()
	d.Poll = func(p, _ string) (Activity, error) {
		w.polled = append(w.polled, p)
		if p == pr {
			return Activity{}, errors.New("HTTP 401: Bad credentials")
		}
		return Activity{State: StateMerged}, nil
	}
	var out bytes.Buffer
	got := Pass(conn, now, DefaultDebounce, d, &out)
	if len(w.polled) != 2 || !got[other] || got[sid] {
		t.Fatalf("polled %v, resumed %v:\n%s", w.polled, got, &out)
	}
	if !strings.Contains(out.String(), "pr-watch: skipped pinnedaa ("+pr+"): ") || !strings.Contains(out.String(), "Bad credentials") {
		t.Errorf("gh failure not reported:\n%s", &out)
	}
}
