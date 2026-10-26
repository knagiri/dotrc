package hibernate

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// fakePID is no process: were a call to slip past the stubs to a real
// syscall.Kill, it would fail with ESRCH rather than signal anything.
const fakePID = 1 << 30

// recorder is a Deps whose every effect is captured, never performed.
type recorder struct {
	calls   []string
	pane    string // FindPane's answer; "" is "not found"
	window  string
	visible map[string]bool
	endErr  error
	present bool // PaneExists after the end
	// agents is what List returns; nil means the one idle session the
	// candidates in these tests name.
	agents  []roster.Agent
	listErr error
	// latest is what LatestEvent returns; nil means the idle_done at
	// interactive()'s IdleSince.
	latest *latestEvent
}

type latestEvent struct {
	state string
	at    int64
	found bool
	err   error
}

const idleAt = 1000

func (r *recorder) deps() Deps {
	return Deps{
		List: func(dir string) ([]roster.Agent, error) {
			r.calls = append(r.calls, "list")
			if r.listErr != nil {
				return nil, r.listErr
			}
			if r.agents != nil {
				return r.agents, nil
			}
			return []roster.Agent{
				{SessionID: "aaaaaaaa-1", Status: roster.StatusIdle},
				{SessionID: "bbbbbbbb-1", Status: roster.StatusIdle},
			}, nil
		},
		LatestEvent: func(id string) (string, int64, bool, error) {
			r.calls = append(r.calls, "latest")
			if r.latest != nil {
				return r.latest.state, r.latest.at, r.latest.found, r.latest.err
			}
			return "idle_done", idleAt, true, nil
		},
		FindPane: func(pid int) (string, bool) {
			r.calls = append(r.calls, "find")
			return r.pane, r.pane != ""
		},
		WindowOf: func(pane string) (string, error) {
			r.calls = append(r.calls, "window "+pane)
			return r.window, nil
		},
		VisibleWindows: func() (map[string]bool, error) {
			r.calls = append(r.calls, "visible")
			return r.visible, nil
		},
		End: func(pid int, sessionID, cfgDir string) error {
			r.calls = append(r.calls, "end "+sessionID)
			return r.endErr
		},
		PaneExists: func(pane string) bool {
			r.calls = append(r.calls, "exists "+pane)
			return r.present
		},
		KillPane: func(pane string) error {
			r.calls = append(r.calls, "kill-pane "+pane)
			return nil
		},
		Stop: func(dir, sessionID string) error {
			r.calls = append(r.calls, "stop "+sessionID)
			return nil
		},
	}
}

func interactive() Candidate {
	return Candidate{SessionID: "aaaaaaaa-1", ConfigDir: dirA, Kind: roster.KindInteractive, PID: fakePID, IdleSince: idleAt}
}

// The destructive ends -- tmux, `claude stop` -- are blocked before any test
// below reaches them: with no tmux or claude on PATH, the real deps cannot run
// either, and the interactive path's effects all land on the recorder.
func TestHibernate_StubsCatchEveryEffect(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	t.Setenv("TMUX", "")
	real := RealDeps(nil)
	if err := real.KillPane("%1"); err == nil {
		t.Fatal("real KillPane ran with an empty PATH")
	}
	if err := real.Stop(dirA, "aaaaaaaa-1"); err == nil {
		t.Fatal("real Stop ran with an empty PATH")
	}
	if _, err := real.VisibleWindows(); err == nil {
		t.Fatal("real VisibleWindows ran with an empty PATH")
	}

	r := &recorder{pane: "%5", window: "@2", visible: map[string]bool{}, present: true}
	if err := Hibernate(interactive(), r.deps()); err != nil {
		t.Fatal(err)
	}
	want := []string{"list", "latest", "find", "window %5", "visible", "end aaaaaaaa-1", "exists %5", "kill-pane %5"}
	if !reflect.DeepEqual(r.calls, want) {
		t.Fatalf("calls = %v, want %v", r.calls, want)
	}
}

// Review focus 1: a pane someone is looking at is not stopped, however long it
// has been idle.
func TestShouldHibernate_VisibleWindowSkipped(t *testing.T) {
	r := &recorder{pane: "%5", window: "@2", visible: map[string]bool{"@2": true}, present: true}
	err := Hibernate(interactive(), r.deps())
	if !IsSkip(err) || !strings.Contains(err.Error(), "on screen") {
		t.Fatalf("err = %v, want an on-screen skip", err)
	}
	for _, c := range r.calls {
		if strings.HasPrefix(c, "end") || strings.HasPrefix(c, "kill-pane") {
			t.Fatalf("calls = %v: a visible session was acted on", r.calls)
		}
	}
	// Another window being on screen does not hold this one back.
	r = &recorder{pane: "%5", window: "@2", visible: map[string]bool{"@9": true}, present: true}
	if err := Hibernate(interactive(), r.deps()); err != nil {
		t.Fatalf("with another window on screen: %v", err)
	}
}

// Review focus 2: an interactive session with no pane of ours is left running.
func TestHibernate_NoPaneSkipped(t *testing.T) {
	r := &recorder{}
	err := Hibernate(interactive(), r.deps())
	if !IsSkip(err) || !strings.Contains(err.Error(), "no tmux pane") {
		t.Fatalf("err = %v, want a no-pane skip", err)
	}
	if !reflect.DeepEqual(r.calls, []string{"list", "latest", "find"}) {
		t.Fatalf("calls = %v, want only the pane lookup", r.calls)
	}
}

// Review focus 3: a session still listed after the SIGTERM keeps its pane.
func TestHibernate_StopTimeoutKeepsPane(t *testing.T) {
	r := &recorder{pane: "%5", window: "@2", visible: map[string]bool{}, present: true,
		endErr: errors.New("session aaaaaaaa is still in the roster after SIGTERM")}
	err := Hibernate(interactive(), r.deps())
	if err == nil || IsSkip(err) || !strings.Contains(err.Error(), "left open") {
		t.Fatalf("err = %v, want a failure naming the pane left open", err)
	}
	for _, c := range r.calls {
		if strings.HasPrefix(c, "kill-pane") {
			t.Fatalf("calls = %v: the pane was closed under a live process", r.calls)
		}
	}
}

// A pane that closed by itself when claude exited is not killed again.
func TestHibernate_PaneAlreadyClosed(t *testing.T) {
	r := &recorder{pane: "%5", window: "@2", visible: map[string]bool{}, present: false}
	if err := Hibernate(interactive(), r.deps()); err != nil {
		t.Fatal(err)
	}
	if got := r.calls[len(r.calls)-1]; got != "exists %5" {
		t.Fatalf("calls = %v, want no kill-pane", r.calls)
	}
}

func TestHibernate_BackgroundUsesStop(t *testing.T) {
	r := &recorder{}
	c := Candidate{SessionID: "bbbbbbbb-1", ConfigDir: dirB, Kind: roster.KindBackground, PID: fakePID, IdleSince: idleAt}
	if err := Hibernate(c, r.deps()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(r.calls, []string{"list", "latest", "stop bbbbbbbb-1"}) {
		t.Fatalf("calls = %v, want only the stop", r.calls)
	}
}

// Check is the dry run's view: the same skips as Hibernate, and no effect.
func TestCheck_ReadsOnly(t *testing.T) {
	r := &recorder{pane: "%5", window: "@2", visible: map[string]bool{}, present: true}
	if err := Check(interactive(), r.deps()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(r.calls, []string{"list", "latest", "find", "window %5", "visible"}) {
		t.Fatalf("calls = %v, want only the reads", r.calls)
	}
	r = &recorder{pane: "%5", window: "@2", visible: map[string]bool{"@2": true}}
	if err := Check(interactive(), r.deps()); !IsSkip(err) {
		t.Fatalf("err = %v, want the on-screen skip", err)
	}
	r = &recorder{}
	bg := Candidate{SessionID: "bbbbbbbb-1", Kind: roster.KindBackground, IdleSince: idleAt}
	if err := Check(bg, r.deps()); err != nil || !reflect.DeepEqual(r.calls, []string{"list", "latest"}) {
		t.Fatalf("background: err = %v, calls = %v", err, r.calls)
	}
}

// Candidates' read can be minutes old by the time a later candidate comes up.
// A session that went busy since is left alone on both paths, with no stop.
func TestHibernate_BusyOnRecheckSkipped(t *testing.T) {
	cases := map[string]Candidate{
		"interactive": interactive(),
		"background":  {SessionID: "bbbbbbbb-1", ConfigDir: dirB, Kind: roster.KindBackground, PID: fakePID, IdleSince: idleAt},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			r := &recorder{pane: "%5", window: "@2", visible: map[string]bool{}, present: true,
				agents: []roster.Agent{{SessionID: c.SessionID, Status: "busy"}}}
			err := Hibernate(c, r.deps())
			if !IsSkip(err) || !strings.Contains(err.Error(), "busy") {
				t.Fatalf("err = %v, want a busy skip", err)
			}
			if !reflect.DeepEqual(r.calls, []string{"list"}) {
				t.Fatalf("calls = %v, want only the re-read", r.calls)
			}
		})
	}
}

func TestHibernate_RecheckUnreadableOrNotOnceSkipped(t *testing.T) {
	idle := roster.Agent{SessionID: "aaaaaaaa-1", Status: roster.StatusIdle}
	cases := map[string]*recorder{
		"unreadable": {listErr: errors.New("claude agents failed")},
		"absent":     {agents: []roster.Agent{{SessionID: "other", Status: roster.StatusIdle}}},
		"duplicated": {agents: []roster.Agent{idle, idle}},
	}
	for name, r := range cases {
		t.Run(name, func(t *testing.T) {
			if err := Hibernate(interactive(), r.deps()); !IsSkip(err) {
				t.Fatalf("err = %v, want a skip", err)
			}
			if !reflect.DeepEqual(r.calls, []string{"list"}) {
				t.Fatalf("calls = %v, want only the re-read", r.calls)
			}
		})
	}
}

// Status alone cannot tell that a session ran a whole turn since Candidates
// looked: it is idle again. The ledger's latest event must still be the
// idle_done Candidates judged.
func TestHibernate_LatestEventChangedSkipped(t *testing.T) {
	cases := map[string]latestEvent{
		"newer idle_done": {state: "idle_done", at: idleAt + 60, found: true},
		"other state":     {state: "working", at: idleAt, found: true},
		"missing":         {},
		"unreadable":      {err: errors.New("db locked")},
	}
	kinds := map[string]Candidate{
		"interactive": interactive(),
		"background":  {SessionID: "bbbbbbbb-1", ConfigDir: dirB, Kind: roster.KindBackground, PID: fakePID, IdleSince: idleAt},
	}
	for name, l := range cases {
		for kname, c := range kinds {
			t.Run(name+"/"+kname, func(t *testing.T) {
				l := l
				r := &recorder{pane: "%5", window: "@2", visible: map[string]bool{}, present: true, latest: &l}
				if err := Hibernate(c, r.deps()); !IsSkip(err) {
					t.Fatalf("err = %v, want a skip", err)
				}
				if !reflect.DeepEqual(r.calls, []string{"list", "latest"}) {
					t.Fatalf("calls = %v, want no stop", r.calls)
				}
			})
		}
	}
}
