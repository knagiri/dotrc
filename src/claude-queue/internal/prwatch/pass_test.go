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
	noTmux   bool
	noDaemon bool
	// noRepoSession: the repo's own tmux session is not there, and the
	// window goes to the last attached session, "main". noSessions: there is
	// none of that either.
	noRepoSession bool
	noSessions    bool

	asked []string // tmux session lookups, in order

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
		SessionExists: func(n string) bool {
			w.asked = append(w.asked, "has "+n)
			return !w.noRepoSession
		},
		LastAttachedSession: func() (string, error) {
			w.asked = append(w.asked, "last")
			if w.noSessions {
				return "", errors.New("tmux list-sessions: no session")
			}
			return "main", nil
		},
		TmuxServerRunning: func() bool { return !w.noTmux },
		DaemonRunning:     func(string) (bool, error) { return !w.noDaemon, nil },
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
// resume -- lands on a world stub, none on a real tmux or claude.
func TestDeliver_StubsCatchEveryEffect(t *testing.T) {
	for _, kind := range []string{roster.KindInteractive, roster.KindBackground} {
		w := &world{latest: "idle_done", noRepoSession: true, agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: kind, Status: roster.StatusIdle}}}
		p := pin(t)
		p.Gone = false
		if err := Deliver(p, "m", w.deps()); err != nil {
			t.Fatalf("%v: %v", kind, err)
		}
		if len(w.ran) != 1 || len(w.ended)+len(w.stopped) != 1 {
			t.Errorf("%v: effects not all captured: ran %q ended %v stopped %v", kind, w.ran, w.ended, w.stopped)
		}
		if kind == roster.KindInteractive && !slices.Equal(w.asked, []string{"has example-repo_feature", "last"}) {
			t.Errorf("tmux session lookups not all captured: %v", w.asked)
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
	if !slices.Equal(argv[:3], []string{"tmux", "new-window", "-d"}) || !slices.Contains(argv, "=example-repo_feature:") {
		t.Errorf("not a detached window in the worktree's tmux session: %q", argv)
	}
	if slices.Contains(w.asked, "last") {
		t.Errorf("looked past the repo's own session: %v", w.asked)
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

// Without the repo's own tmux session, the window goes to the session a
// client was attached to last; no session is created, because one made from
// the service would take its environment (no SSH agent) for all its windows.
func TestDeliver_NoRepoSessionUsesLastAttached(t *testing.T) {
	w := &world{noRepoSession: true}
	if err := Deliver(pin(t), "m", w.deps()); err != nil {
		t.Fatal(err)
	}
	if len(w.ran) != 1 {
		t.Fatalf("ran %q", w.ran)
	}
	argv := w.ran[0]
	if slices.Contains(argv, "new-session") {
		t.Errorf("created a tmux session from the service: %q", argv)
	}
	if !slices.Equal(argv[:3], []string{"tmux", "new-window", "-d"}) || !slices.Contains(argv, "=main:") {
		t.Errorf("not a detached window in the last attached session: %q", argv)
	}
}

// With no session to put the window in, nothing is launched and the delivery
// waits for the next pass.
func TestDeliver_NoSessionSkipped(t *testing.T) {
	w := &world{noRepoSession: true, noSessions: true}
	err := Deliver(pin(t), "m", w.deps())
	if !hibernate.IsSkip(err) || !strings.Contains(err.Error(), "no tmux session") {
		t.Fatalf("err = %v", err)
	}
	if len(w.ran) != 0 {
		t.Errorf("ran %q", w.ran)
	}
}

// An existing tmux session gets a new window, detached so a person attached
// to that session keeps looking at what they were looking at.
func TestDeliver_ExistingSessionNewWindowDetached(t *testing.T) {
	w := &world{}
	d := w.deps()
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
	if want := []string{"claude", "--bg", "--resume", sid, "m"}; !slices.Equal(w.ran[0], want) {
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
	want := []string{"claude", "--bg", "--resume", sid, "m"}
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
		{Kind: KindReview, ReviewState: "CHANGES_REQUESTED"},
		{Kind: KindComment, Bot: true},
		{Kind: KindReview, ReviewState: "CHANGES_REQUESTED"},
		{Kind: KindReview, Bot: true, ReviewState: "COMMENTED"},
	})
	for _, want := range []string{
		"PR " + pr + " に新しい活動があります",
		"- review changes_requested（人）: 2 件",
		"- comment（bot）: 1 件",
		"- review commented（bot）: 1 件",
		"`gh-pr-comments 12`", "信頼できない外部入力", "delegate-to-worktree",
	} {
		if !strings.Contains(m, want) {
			t.Errorf("message lacks %q:\n%s", want, m)
		}
	}
}

// Nothing a PR's commenters wrote reaches the message: the bodies are not
// even read (see TestPoll_IgnoresBodies), and neither are logins.
func TestMessage_CarriesNoBodyOrLogin(t *testing.T) {
	a, err := parse([]byte(injection))
	if err != nil {
		t.Fatal(err)
	}
	m := Message(pr, a, a.Events)
	for _, bad := range []string{"Ignore previous instructions", "rm -rf", "example-user", "example-bot"} {
		if strings.Contains(m, bad) {
			t.Errorf("message carries %q:\n%s", bad, m)
		}
	}
	if !strings.Contains(m, "- review changes_requested（人）: 1 件") || !strings.Contains(m, "- comment（bot）: 1 件") {
		t.Errorf("message lost the counts:\n%s", m)
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
// 10:00.
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
	{Kind: KindReview, At: at("09:00"), ReviewState: "APPROVED"},
	{Kind: KindComment, At: at("10:30")},
	{Kind: KindReview, Bot: true, At: at("10:40"), ReviewState: "COMMENTED"},
}}

// The first pass that sees new activity only records it; the next one, a tick
// later, delivers it all at once. The cursor stays where it was until a later
// pass finds the session's UserPromptSubmit since the delivery, and then moves
// to the newest delivered event.
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
	delivered := now.Add(3 * time.Minute)
	got := Pass(conn, delivered, DefaultDebounce, w.deps(), &out)
	if !got[sid] || len(w.ran) != 1 {
		t.Fatalf("second pass: resumed %v, ran %q\n%s", got, w.ran, &out)
	}
	cmd := w.ran[0][len(w.ran[0])-1]
	if !strings.Contains(cmd, "comment（人）: 1 件") || !strings.Contains(cmd, "review commented（bot）: 1 件") || strings.Contains(cmd, "approved") {
		t.Errorf("delivered message = %q", cmd)
	}
	if _, cursor, _ := pinState(t, conn, sid); cursor.String != "2026-10-26T10:00:00Z" {
		t.Errorf("cursor moved on the launch alone: %v", cursor)
	}
	prompt(t, conn, sid, delivered.Unix()+5)
	Pass(conn, delivered.Add(3*time.Minute), DefaultDebounce, w.deps(), &out)
	pinned, cursor, seen := pinState(t, conn, sid)
	if !pinned || cursor.String != "2026-10-26T10:40:00Z" || seen.Valid {
		t.Errorf("after the prompt: pinned=%v cursor=%v seen=%v\n%s", pinned, cursor, seen, &out)
	}
	if at, _ := deliveredState(t, conn, sid); at.Valid {
		t.Errorf("delivery record left after confirmation: %v", at)
	}
	// Nothing newer: the next pass delivers nothing.
	Pass(conn, delivered.Add(6*time.Minute), DefaultDebounce, w.deps(), &out)
	if len(w.ran) != 1 {
		t.Errorf("delivered again: %q", w.ran)
	}
}

// A resume that failed inside its window leaves no UserPromptSubmit. The pass
// right after the delivery keeps the cursor and waits; once ConfirmWindow (two
// ticks) has passed, the record is dropped and the next pass delivers again.
// A prompt from before the delivery does not count.
func TestPass_UnconfirmedDeliveryRedelivered(t *testing.T) {
	conn := ledger(t, sid)
	if err := db.SetPRSeen(conn, sid, pr, now.Unix()-600); err != nil {
		t.Fatal(err)
	}
	prompt(t, conn, sid, now.Unix()-60)
	w := &world{activity: news}
	var out bytes.Buffer
	if got := Pass(conn, now, DefaultDebounce, w.deps(), &out); !got[sid] || len(w.ran) != 1 {
		t.Fatalf("not delivered: %v\n%s", got, &out)
	}
	for _, tick := range []time.Duration{3 * time.Minute, 6 * time.Minute} {
		Pass(conn, now.Add(tick), DefaultDebounce, w.deps(), &out)
		if _, cursor, _ := pinState(t, conn, sid); cursor.String != "2026-10-26T10:00:00Z" {
			t.Fatalf("+%v: cursor moved without a prompt: %v", tick, cursor)
		}
		if len(w.ran) != 1 {
			t.Fatalf("+%v: delivered again before the window closed: %q\n%s", tick, w.ran, &out)
		}
	}
	if at, _ := deliveredState(t, conn, sid); at.Valid {
		t.Fatalf("record kept past ConfirmWindow: %v\n%s", at, &out)
	}
	if !strings.Contains(out.String(), "delivering again on the next pass") {
		t.Errorf("failure not reported:\n%s", &out)
	}
	Pass(conn, now.Add(9*time.Minute), DefaultDebounce, w.deps(), &out)
	if len(w.ran) != 2 {
		t.Errorf("not delivered again: ran %d times\n%s", len(w.ran), &out)
	}
}

func prompt(t *testing.T, conn *sql.DB, id string, at int64) {
	t.Helper()
	if _, err := conn.Exec("INSERT INTO events(session_id, event_type, state, created_at) VALUES (?, 'UserPromptSubmit', 'working', ?)", id, at); err != nil {
		t.Fatal(err)
	}
}

func deliveredState(t *testing.T, conn *sql.DB, id string) (at sql.NullInt64, upTo sql.NullString) {
	t.Helper()
	if err := conn.QueryRow("SELECT pin_delivered_at, pin_delivered_upto FROM sessions WHERE session_id = ?", id).Scan(&at, &upTo); err != nil {
		t.Fatal(err)
	}
	return
}

// A failed or skipped launch records nothing, so the next pass retries with the
// same activity; once a launch succeeds, it is not delivered again while
// awaiting confirmation.
func TestPass_FailedLaunchRetried(t *testing.T) {
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
	if pinned, _, _ := pinState(t, conn, sid); !pinned {
		t.Fatal("unpinned on the launch alone")
	}
	prompt(t, conn, sid, now.Unix())
	Pass(conn, now.Add(3*time.Minute), DefaultDebounce, w.deps(), &out)
	if pinned, _, _ := pinState(t, conn, sid); pinned {
		t.Errorf("still pinned after the merge was taken in:\n%s", &out)
	}
	pins, err := db.PRPins(conn)
	if err != nil || len(pins) != 0 {
		t.Errorf("PRPins after merge = %v, %v", pins, err)
	}
	if len(w.ran) != 1 {
		t.Errorf("delivered again: %q", w.ran)
	}
}

// A merge whose resume left no prompt keeps the pin and is delivered again.
func TestPass_MergedUnconfirmedRedelivered(t *testing.T) {
	conn := ledger(t, sid)
	w := &world{activity: Activity{State: StateMerged}}
	var out bytes.Buffer
	for _, tick := range []time.Duration{0, 3 * time.Minute, 6 * time.Minute, 9 * time.Minute} {
		Pass(conn, now.Add(tick), DefaultDebounce, w.deps(), &out)
	}
	if pinned, _, _ := pinState(t, conn, sid); !pinned {
		t.Errorf("unpinned without a prompt:\n%s", &out)
	}
	if len(w.ran) != 2 {
		t.Errorf("want the delivery and one redelivery, ran %d times:\n%s", len(w.ran), &out)
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

// Without a tmux server, or without the config dir's claude daemon, nothing
// is launched -- either would be started here with the service's environment
// -- and a running session is not stopped first.
func TestDeliver_NoHostSkipped(t *testing.T) {
	for _, tc := range []struct {
		name        string
		w           *world
		gone        bool
		kind, inMsg string
	}{
		{"gone interactive, no tmux server", &world{noTmux: true}, true, db.KindInteractive, "no tmux server"},
		{"gone background, no daemon", &world{noDaemon: true}, true, db.KindBackground, "no claude daemon"},
		{"running interactive, no tmux server", &world{noTmux: true, latest: "idle_done",
			agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: roster.KindInteractive, Status: roster.StatusIdle}}}, false, db.KindInteractive, "no tmux server"},
		{"running background, no daemon", &world{noDaemon: true, latest: "idle_done",
			agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: roster.KindBackground, Status: roster.StatusIdle}}}, false, db.KindBackground, "no claude daemon"},
	} {
		p := pin(t)
		p.Gone, p.Kind = tc.gone, tc.kind
		err := Deliver(p, "m", tc.w.deps())
		if !hibernate.IsSkip(err) || !strings.Contains(err.Error(), tc.inMsg) {
			t.Errorf("%s: err = %v", tc.name, err)
		}
		if n := len(tc.w.ran) + len(tc.w.ended) + len(tc.w.stopped); n != 0 {
			t.Errorf("%s: acted anyway: ran %q ended %v stopped %v", tc.name, tc.w.ran, tc.w.ended, tc.w.stopped)
		}
	}
}

// Stopping the last background session can let its daemon exit; the resume is
// then not launched, rather than starting a new daemon from the service.
func TestDeliver_DaemonGoneAfterStop(t *testing.T) {
	w := &world{latest: "idle_done", agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: roster.KindBackground, Status: roster.StatusIdle}}}
	d := w.deps()
	d.DaemonRunning = func(string) (bool, error) { return len(w.stopped) == 0, nil }
	p := pin(t)
	p.Gone = false
	err := Deliver(p, "m", d)
	if !hibernate.IsSkip(err) || !strings.Contains(err.Error(), "stopped, but not resumed") {
		t.Fatalf("err = %v", err)
	}
	if !slices.Equal(w.stopped, []string{sid}) || len(w.ran) != 0 {
		t.Errorf("stopped %v ran %q", w.stopped, w.ran)
	}
}

// Closing an interactive session's pane can be what ends the tmux server (it
// was the last window); the resume must not start a new one with this
// process's environment.
func TestDeliver_TmuxServerGoneAfterStop(t *testing.T) {
	w := &world{latest: "idle_done", agents: []roster.Agent{{SessionID: sid, PID: stray, Kind: roster.KindInteractive, Status: roster.StatusIdle}}}
	d := w.deps()
	d.TmuxServerRunning = func() bool { return len(w.killed) == 0 }
	p := pin(t)
	p.Gone = false
	err := Deliver(p, "m", d)
	if !hibernate.IsSkip(err) || !strings.Contains(err.Error(), "stopped, but not resumed") {
		t.Fatalf("err = %v", err)
	}
	if !slices.Equal(w.killed, []string{"%7"}) || len(w.ran) != 0 {
		t.Errorf("killed %v ran %q", w.killed, w.ran)
	}
}

func failState(t *testing.T, conn *sql.DB, id string) (failures sql.NullInt64, halted, note sql.NullString) {
	t.Helper()
	if err := conn.QueryRow("SELECT pin_failures, pin_halted_upto, pin_note FROM sessions WHERE session_id = ?", id).Scan(&failures, &halted, &note); err != nil {
		t.Fatal(err)
	}
	return
}

// tripwire puts tmux, claude, gh and mise on PATH that only leave a mark, so a
// launch that went past the world stub to a real command shows up as the
// mark instead of a window or a resumed session.
func tripwire(t *testing.T) string {
	t.Helper()
	bin, mark := t.TempDir(), filepath.Join(t.TempDir(), "reached")
	for _, name := range []string{"tmux", "claude", "gh", "mise"} {
		script := "#!/bin/sh\necho " + name + " >> '" + mark + "'\nexit 1\n"
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin)
	return mark
}

// unconfirmed runs the passes of one delivery that never sees a prompt: the
// pass at *clock delivers, and the one ConfirmWindow later drops it as
// failed. *clock ends a tick after that, where the next delivery would be.
func unconfirmed(t *testing.T, conn *sql.DB, w *world, clock *time.Time, out *bytes.Buffer) {
	t.Helper()
	Pass(conn, *clock, DefaultDebounce, w.deps(), out)
	*clock = clock.Add(ConfirmWindow)
	Pass(conn, *clock, DefaultDebounce, w.deps(), out)
	*clock = clock.Add(3 * time.Minute)
}

// halted is a ledger whose pin has had MaxFailures unconfirmed deliveries of
// news in a row.
func halted(t *testing.T, w *world, clock *time.Time, out *bytes.Buffer) *sql.DB {
	t.Helper()
	conn := ledger(t, sid)
	if err := db.SetPRSeen(conn, sid, pr, now.Unix()-600); err != nil {
		t.Fatal(err)
	}
	*clock = now
	for range MaxFailures {
		unconfirmed(t, conn, w, clock, out)
	}
	return conn
}

func TestPass_RetryCap(t *testing.T) {
	// Every launch of the first subtest lands on the world stub: the tmux,
	// claude, gh and mise on PATH are never run (its tripwire shows it).
	t.Run("stubs catch every launch", func(t *testing.T) {
		mark := tripwire(t)
		w := &world{activity: news}
		var clock time.Time
		var out bytes.Buffer
		halted(t, w, &clock, &out)
		if len(w.ran) != MaxFailures || w.ran[0][0] != "tmux" {
			t.Errorf("launches not captured by the stub: %q\n%s", w.ran, &out)
		}
		if b, err := os.ReadFile(mark); err == nil {
			t.Errorf("a real command was run: %s", b)
		}
	})

	t.Run("stops at the third failure", func(t *testing.T) {
		w := &world{activity: news}
		var clock time.Time
		var out bytes.Buffer
		conn := halted(t, w, &clock, &out)
		failures, up, note := failState(t, conn, sid)
		if failures.Int64 != MaxFailures || up.String != "2026-10-26T10:40:00Z" || note.String != HaltNote {
			t.Errorf("failures=%v halted=%v note=%v", failures, up, note)
		}
		if !strings.Contains(out.String(), "3 times in a row; delivery stopped") {
			t.Errorf("the stop is not reported:\n%s", &out)
		}
		if strings.Count(out.String(), "delivering again on the next pass") != MaxFailures-1 {
			t.Errorf("want %d retries reported:\n%s", MaxFailures-1, &out)
		}
	})

	t.Run("stopped pin is polled but not delivered to", func(t *testing.T) {
		w := &world{activity: news}
		var clock time.Time
		var out bytes.Buffer
		conn := halted(t, w, &clock, &out)
		polled := len(w.polled)
		out.Reset()
		for range 4 {
			Pass(conn, clock, DefaultDebounce, w.deps(), &out)
			clock = clock.Add(3 * time.Minute)
		}
		if len(w.ran) != MaxFailures {
			t.Errorf("delivered after the stop: ran %d times\n%s", len(w.ran), &out)
		}
		if len(w.polled) != polled+4 {
			t.Errorf("the stopped pin is not polled: %d polls", len(w.polled)-polled)
		}
		if !strings.Contains(out.String(), "delivery stopped after 3 unconfirmed resumes") {
			t.Errorf("the stop is not reported on later passes:\n%s", &out)
		}
	})

	t.Run("newer activity resumes", func(t *testing.T) {
		w := &world{activity: news}
		var clock time.Time
		var out bytes.Buffer
		conn := halted(t, w, &clock, &out)
		w.activity = Activity{State: StateOpen, Events: append(slices.Clone(news.Events), Event{Kind: KindComment, At: at("10:50")})}
		Pass(conn, clock, DefaultDebounce, w.deps(), &out)
		if failures, up, _ := failState(t, conn, sid); failures.Valid || up.Valid {
			t.Errorf("stop not lifted: failures=%v halted=%v", failures, up)
		}
		if len(w.ran) != MaxFailures {
			t.Errorf("resumed delivery skipped the debounce: ran %d times\n%s", len(w.ran), &out)
		}
		Pass(conn, clock.Add(3*time.Minute), DefaultDebounce, w.deps(), &out)
		if len(w.ran) != MaxFailures+1 {
			t.Fatalf("not delivered after the stop was lifted: ran %d times\n%s", len(w.ran), &out)
		}
		if cmd := w.ran[MaxFailures][len(w.ran[MaxFailures])-1]; !strings.Contains(cmd, "comment（人）: 2 件") {
			t.Errorf("the resumed delivery does not carry what piled up: %q", cmd)
		}
	})

	t.Run("merge resumes", func(t *testing.T) {
		w := &world{activity: news}
		var clock time.Time
		var out bytes.Buffer
		conn := halted(t, w, &clock, &out)
		w.activity = Activity{State: StateMerged, Events: news.Events}
		Pass(conn, clock, DefaultDebounce, w.deps(), &out)
		if len(w.ran) != MaxFailures+1 || !strings.Contains(w.ran[MaxFailures][len(w.ran[MaxFailures])-1], "merge されました") {
			t.Errorf("merge not delivered after the stop: %q\n%s", w.ran, &out)
		}
	})

	// A stop on a merge has nothing newer to wait for.
	t.Run("stop on a merge stays", func(t *testing.T) {
		conn := ledger(t, sid)
		// news.Events are newer than the cursor, so a merge stop that wrongly
		// waited on "newer activity" would resume at once.
		w := &world{activity: Activity{State: StateMerged, Events: news.Events}}
		clock := now
		var out bytes.Buffer
		for range MaxFailures {
			unconfirmed(t, conn, w, &clock, &out)
		}
		Pass(conn, clock, DefaultDebounce, w.deps(), &out)
		if len(w.ran) != MaxFailures {
			t.Errorf("delivered after the stop: ran %d times\n%s", len(w.ran), &out)
		}
		// A comment after the merge is not a reason to resume either.
		w.activity.Events = append(slices.Clone(news.Events), Event{Kind: KindComment, At: at("11:00")})
		Pass(conn, clock.Add(3*time.Minute), DefaultDebounce, w.deps(), &out)
		if len(w.ran) != MaxFailures {
			t.Errorf("delivered after a comment on the merged PR: ran %d times\n%s", len(w.ran), &out)
		}
		if failures, up, _ := failState(t, conn, sid); failures.Int64 != MaxFailures || up.Valid {
			t.Errorf("failures=%v halted=%v", failures, up)
		}
	})

	// A reopen lifts a merge stop even with nothing newer than the cursor, and
	// the pending mark from before the stop must not survive it.
	t.Run("reopen clears the old pending mark", func(t *testing.T) {
		conn := ledger(t, sid)
		if err := db.SetPRSeen(conn, sid, pr, now.Unix()-3600); err != nil {
			t.Fatal(err)
		}
		w := &world{activity: Activity{State: StateMerged}}
		clock := now
		var out bytes.Buffer
		for range MaxFailures {
			unconfirmed(t, conn, w, &clock, &out)
		}
		// Reopened; its one event is older than the cursor (10:00).
		w.activity = Activity{State: StateOpen, Events: []Event{{Kind: KindReview, At: at("09:00")}}}
		Pass(conn, clock, DefaultDebounce, w.deps(), &out)
		if failures, up, _ := failState(t, conn, sid); failures.Valid || up.Valid {
			t.Fatalf("stop not lifted by the reopen: failures=%v halted=%v\n%s", failures, up, &out)
		}
		if _, _, seen := pinState(t, conn, sid); seen.Valid {
			t.Errorf("pin_seen_at survived the resume: %v", seen)
		}
		w.activity.Events = append(w.activity.Events, Event{Kind: KindComment, At: at("11:30")})
		clock = clock.Add(3 * time.Minute)
		Pass(conn, clock, DefaultDebounce, w.deps(), &out)
		if len(w.ran) != MaxFailures {
			t.Fatalf("delivered without the debounce: ran %d times\n%s", len(w.ran), &out)
		}
		Pass(conn, clock.Add(DefaultDebounce), DefaultDebounce, w.deps(), &out)
		if len(w.ran) != MaxFailures+1 {
			t.Errorf("not delivered after the debounce: ran %d times\n%s", len(w.ran), &out)
		}
	})

	t.Run("confirmed delivery resets the count", func(t *testing.T) {
		conn := ledger(t, sid)
		if err := db.SetPRSeen(conn, sid, pr, now.Unix()-600); err != nil {
			t.Fatal(err)
		}
		w := &world{activity: news}
		clock := now
		var out bytes.Buffer
		for range MaxFailures - 1 {
			unconfirmed(t, conn, w, &clock, &out)
		}
		if failures, _, _ := failState(t, conn, sid); failures.Int64 != MaxFailures-1 {
			t.Fatalf("failures = %v\n%s", failures, &out)
		}
		Pass(conn, clock, DefaultDebounce, w.deps(), &out)
		prompt(t, conn, sid, clock.Unix()+5)
		Pass(conn, clock.Add(3*time.Minute), DefaultDebounce, w.deps(), &out)
		if failures, up, note := failState(t, conn, sid); failures.Valid || up.Valid || note.Valid {
			t.Errorf("after a confirmed delivery: failures=%v halted=%v note=%v\n%s", failures, up, note, &out)
		}
	})

	t.Run("note prefix is not repeated", func(t *testing.T) {
		w := &world{activity: news}
		var clock time.Time
		var out bytes.Buffer
		conn := ledger(t, sid)
		note := "Copilot の review 待ち"
		if err := db.SetPin(conn, sid, &note); err != nil {
			t.Fatal(err)
		}
		if err := db.SetPRSeen(conn, sid, pr, now.Unix()-600); err != nil {
			t.Fatal(err)
		}
		clock = now
		want := HaltNote + " " + note
		for round, last := range []string{"10:50", "11:00"} {
			for range MaxFailures {
				unconfirmed(t, conn, w, &clock, &out)
			}
			if _, _, got := failState(t, conn, sid); got.String != want {
				t.Fatalf("round %d: note = %q, want %q", round, got.String, want)
			}
			// Newer activity lifts the stop and starts the next round.
			w.activity.Events = append(slices.Clone(w.activity.Events), Event{Kind: KindComment, At: at(last)})
			Pass(conn, clock, DefaultDebounce, w.deps(), &out)
			clock = clock.Add(3 * time.Minute)
		}
		if len(w.ran) != 2*MaxFailures {
			t.Errorf("ran %d times\n%s", len(w.ran), &out)
		}
	})

	// Putting the pin on again (claude-queue pin, the picker's ctrl-t) lifts
	// the stop at once, with no new activity.
	t.Run("re-pin resets the count", func(t *testing.T) {
		w := &world{activity: news}
		var clock time.Time
		var out bytes.Buffer
		conn := halted(t, w, &clock, &out)
		note := "見直した"
		if err := db.SetPin(conn, sid, &note); err != nil {
			t.Fatal(err)
		}
		if failures, up, _ := failState(t, conn, sid); failures.Valid || up.Valid {
			t.Fatalf("re-pin kept the stop: failures=%v halted=%v", failures, up)
		}
		Pass(conn, clock, DefaultDebounce, w.deps(), &out)
		if len(w.ran) != MaxFailures+1 {
			t.Errorf("not delivered after the re-pin: ran %d times\n%s", len(w.ran), &out)
		}
	})
}
