package picker

import (
	"database/sql"
	"errors"
	"strings"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

func nowUnix() int64         { return 1_800_000_000 }
func nowMinus(d int64) int64 { return nowUnix() - d }

func TestFormatLine_AwaitingApproval(t *testing.T) {
	row := db.Row{
		SessionID:      "s1",
		TmuxPane:       sql.NullString{String: "%1", Valid: true},
		Cwd:            sql.NullString{String: "/home/x/projects/everysteel-api", Valid: true},
		EffectiveState: "awaiting_approval",
		TranscriptPath: sql.NullString{String: "/home/x/.claude/projects/enc/s1.jsonl", Valid: true},
		Payload:        sql.NullString{String: `{"tool_name":"Bash","tool_input":{"command":"pnpm prisma migrate"}}`, Valid: true},
		CreatedAt:      nowMinus(120),
	}
	got := FormatLine(row, "everysteel-api", nowUnix(), false)
	fields := strings.Split(got, "\t")
	if len(fields) != 8 {
		t.Fatalf("want 8 tab-separated fields, got %d: %q", len(fields), got)
	}
	if fields[0] != "⏳" {
		t.Errorf("icon = %q, want ⏳", fields[0])
	}
	if fields[1] != "everysteel-api" {
		t.Errorf("worktree = %q, want everysteel-api", fields[1])
	}
	if !strings.Contains(fields[2], "Bash: pnpm prisma migrate") {
		t.Errorf("summary = %q", fields[2])
	}
	if fields[3] != "2m" {
		t.Errorf("age = %q, want 2m", fields[3])
	}
	if fields[4] != "s1" {
		t.Errorf("hidden session id = %q, want s1", fields[4])
	}
	if fields[5] != "%1" {
		t.Errorf("hidden tmux_pane = %q, want %%1", fields[5])
	}
	if fields[6] != "/home/x/projects/everysteel-api" {
		t.Errorf("hidden cwd = %q, want the full path", fields[6])
	}
	// The resume path refuses to run without a transcript, so the path has to
	// reach the pick through this hidden column.
	if fields[7] != "/home/x/.claude/projects/enc/s1.jsonl" {
		t.Errorf("hidden transcript_path = %q, want the full path", fields[7])
	}
}

// A row the ledger has no transcript for still renders; the column is empty,
// which is what resumeBlocked reads as "nothing to resume".
func TestFormatLine_NoTranscript(t *testing.T) {
	row := db.Row{SessionID: "s3", EffectiveState: "idle_done", CreatedAt: nowMinus(10)}
	fields := strings.Split(FormatLine(row, "wt", nowUnix(), false), "\t")
	if len(fields) != 8 {
		t.Fatalf("want 8 fields, got %d", len(fields))
	}
	if fields[7] != "" {
		t.Errorf("hidden transcript_path = %q, want empty", fields[7])
	}
}

// The visible column names the worktree, which is not the cwd's basename when
// the session was started in a subdirectory. Getting the cwd's basename here
// is the bug this column had: a session recorded under .../src/claude-queue
// showed up as "claude-queue" and could not be found by its worktree name.
func TestFormatLine_DeepCwdShowsWorktree(t *testing.T) {
	const cwd = "/home/x/ghq/github.com/knagiri/dotrc_queue-picker/src/claude-queue"
	row := db.Row{
		SessionID:      "s2",
		Cwd:            sql.NullString{String: cwd, Valid: true},
		EffectiveState: "idle_done",
		CreatedAt:      nowMinus(30),
	}
	fields := strings.Split(FormatLine(row, "dotrc_queue-picker", nowUnix(), false), "\t")
	if fields[1] != "dotrc_queue-picker" {
		t.Errorf("worktree = %q, want dotrc_queue-picker", fields[1])
	}
	// The full cwd still rides along hidden: the attach path opens the window
	// in the directory the session actually ran in.
	if fields[6] != cwd {
		t.Errorf("hidden cwd = %q, want %q", fields[6], cwd)
	}
}

func TestFormatAge(t *testing.T) {
	cases := []struct {
		sec  int64
		want string
	}{
		{30, "30s"},
		{119, "119s"},
		{120, "2m"},
		{60 * 59, "59m"},
		{60 * 60, "1h"},
		{60 * 60 * 24 * 2, "2d"},
	}
	for _, c := range cases {
		if got := formatAge(c.sec); got != c.want {
			t.Errorf("formatAge(%d) = %q, want %q", c.sec, got, c.want)
		}
	}
}

const testUUID = "61c846eb-8205-4a8e-8a0d-7772410051c9"

// resumable is a Target whose resume preconditions all hold, so each case below
// can state only the field it is about.
func resumable() Target {
	return Target{
		SessionID:        testUUID,
		Cwd:              "/w/a",
		TranscriptPath:   "/t/a.jsonl",
		RosterOK:         true,
		TranscriptExists: true,
		CwdExists:        true,
	}
}

// DecideAction is the whole routing rule, and every one of its branches decides
// whether a live process gets a SIGTERM -- so all of them are covered here
// rather than only the interesting ones. The exec calls they route to are
// one-liners in the multiplexer.
func TestDecideAction(t *testing.T) {
	withPane := func(f func(*Target)) Target {
		tgt := resumable()
		f(&tgt)
		return tgt
	}

	cases := []struct {
		name    string
		target  Target
		kind    string
		short   string
		pane    string
		resume  string
		killPID int
	}{{
		// A reachable pane wins over everything else: the session is right there.
		name:   "reachable pane switches",
		target: withPane(func(tg *Target) { tg.Pane = "%12" }),
		kind:   "switch",
		pane:   "%12",
	}, {
		// Even a live interactive session on another server: if its pane came
		// back reachable, nothing may be killed.
		name: "reachable pane beats an orphan process",
		target: withPane(func(tg *Target) {
			tg.Pane, tg.InRoster, tg.Kind, tg.PID, tg.Origin = "%12", true, "interactive", 4242, originOrphan
		}),
		kind: "switch",
		pane: "%12",
	}, {
		name:   "no session id is not actionable",
		target: withPane(func(tg *Target) { tg.SessionID = "" }),
		kind:   "none",
	}, {
		// An unreadable roster is not evidence the process ended, and resuming
		// a live session puts two of them on one transcript.
		name:   "unreadable roster refuses to resume",
		target: withPane(func(tg *Target) { tg.RosterOK = false }),
		kind:   "none",
	}, {
		// `claude attach` only accepts the 8-char short id; the full UUID
		// fails with "No job matching".
		name: "background session attaches by short id",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID = true, "background", 100
		}),
		kind:  "attach",
		short: "61c846eb",
	}, {
		// Short ids that are already <= 8 chars must not be sliced out of range.
		name: "short session id is not truncated",
		target: withPane(func(tg *Target) {
			tg.SessionID, tg.InRoster, tg.Kind, tg.PID = "abc", true, "background", 100
		}),
		kind:  "attach",
		short: "abc",
	}, {
		// `claude agents --json` has been observed to list the same session id
		// under two pids at once -- the duplicate-transcript state a resume
		// must not create. There is no single pid to act on without guessing,
		// so this refuses rather than kill one of the two arbitrarily.
		name: "duplicate roster entries are not touched",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originOrphan
			tg.RosterMatches, tg.DuplicatePIDs = 2, []int{4242, 5252}
		}),
		kind: "none",
	}, {
		// The one case that may kill: the process provably belongs to a tmux
		// server no client of ours can reach.
		name: "orphan interactive session is ended then resumed",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originOrphan
		}),
		kind:    "resume",
		resume:  testUUID,
		killPID: 4242,
	}, {
		name: "session started outside tmux is left alone",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originOutside
		}),
		kind: "none",
	}, {
		// /proc unreadable, TMUX unparseable, or no server pid of our own: the
		// safe answer is the same as for a session in use elsewhere.
		name: "unknown origin is left alone",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originUnknown
		}),
		kind: "none",
	}, {
		name: "same-server session with a closed pane is left alone",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originCurrent
		}),
		kind: "none",
	}, {
		name: "orphan with no pid cannot be ended, so is left alone",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 0, originOrphan
		}),
		kind: "none",
	}, {
		// Nothing to displace, so no kill: this is the plain resume.
		name:   "session absent from the roster resumes directly",
		target: resumable(),
		kind:   "resume",
		resume: testUUID,
	}, {
		name:   "no recorded transcript blocks the resume",
		target: withPane(func(tg *Target) { tg.TranscriptPath, tg.TranscriptExists = "", false }),
		kind:   "none",
	}, {
		// Short-lived sessions never write a jsonl, so a recorded path is only
		// half the check. `claude --resume` with an id it cannot find starts an
		// empty session under that id instead of failing.
		name:   "transcript missing on disk blocks the resume",
		target: withPane(func(tg *Target) { tg.TranscriptExists = false }),
		kind:   "none",
	}, {
		name:   "no recorded cwd blocks the resume",
		target: withPane(func(tg *Target) { tg.Cwd, tg.CwdExists = "", false }),
		kind:   "none",
	}, {
		// A reaped worktree takes the cwd resume resolves transcripts against.
		name:   "reaped cwd blocks the resume",
		target: withPane(func(tg *Target) { tg.CwdExists = false }),
		kind:   "none",
	}, {
		// The preconditions gate the kill path too: an orphan whose transcript
		// is gone must not be killed for a resume that cannot happen.
		name: "orphan with no transcript is not killed",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originOrphan
			tg.TranscriptExists = false
		}),
		kind: "none",
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := DecideAction(c.target)
			if got.Kind != c.kind {
				t.Fatalf("Kind = %q, want %q (%+v)", got.Kind, c.kind, got)
			}
			if got.Pane != c.pane {
				t.Errorf("Pane = %q, want %q", got.Pane, c.pane)
			}
			if got.Short != c.short {
				t.Errorf("Short = %q, want %q", got.Short, c.short)
			}
			if got.Resume != c.resume {
				t.Errorf("Resume = %q, want %q", got.Resume, c.resume)
			}
			if got.KillPID != c.killPID {
				t.Errorf("KillPID = %d, want %d", got.KillPID, c.killPID)
			}
			if c.kind == "none" && got.Reason == "" {
				t.Error("none without a reason: the pick would look like a no-op")
			}
			if c.kind == "attach" || c.kind == "resume" {
				if got.Cwd != c.target.Cwd {
					t.Errorf("Cwd = %q, want %q", got.Cwd, c.target.Cwd)
				}
			}
		})
	}
}

// A row whose tmux_pane went NULL still has a live process, and when that
// process runs in the current tmux server the picker must switch to its pane
// rather than fall through to `claude attach` -- which only serves background
// jobs and would silently close a fresh window for an interactive session.
func TestPaneForSession(t *testing.T) {
	agents := []roster.Agent{
		{SessionID: "bg", PID: 100, Kind: "background"},
		{SessionID: "live", PID: 200, Kind: "interactive"},
	}
	// Only pid 200 sits under a pane; 100 is a background agent with none.
	find := func(pid int) (string, bool) {
		if pid == 200 {
			return "%7", true
		}
		return "", false
	}

	if got := paneForSession(agents, "live", find); got != "%7" {
		t.Errorf("paneForSession(live) = %q, want %%7", got)
	}
	// A live agent with no pane must stay empty so DecideAction routes it to
	// attach, which is the correct path for a background session.
	if got := paneForSession(agents, "bg", find); got != "" {
		t.Errorf("paneForSession(bg) = %q, want empty", got)
	}
	// A session the roster does not list is already gone; nothing to resolve.
	if got := paneForSession(agents, "missing", find); got != "" {
		t.Errorf("paneForSession(missing) = %q, want empty", got)
	}
	if got := paneForSession(nil, "live", find); got != "" {
		t.Errorf("paneForSession over an empty roster = %q, want empty", got)
	}
}

// fakeMux is a Multiplexer whose pane answers are set per test. Only the
// lookups reachablePane makes are wired; Switch and OpenSession are the exec
// one-liners this package does not test.
type fakeMux struct {
	panes     map[string]bool // PaneExists
	find      map[int]string  // FindPane
	serverPID int             // ServerPID; 0 means "no server"
}

func (f *fakeMux) PaneID() string                                 { return "" }
func (f *fakeMux) RefreshStatus()                                 {}
func (f *fakeMux) Switch(target string) error                     { return nil }
func (f *fakeMux) OpenSession(name, cwd string, a []string) error { return nil }
func (f *fakeMux) FindPane(pid int) (string, bool) {
	pane, ok := f.find[pid]
	return pane, ok
}
func (f *fakeMux) PaneExists(target string) bool { return f.panes[target] }
func (f *fakeMux) ServerPID() (int, bool)        { return f.serverPID, f.serverPID > 0 }

// The ledger's pane column is not identity-checked: PaneExists only proves
// *some* pane on this server has that id, not that it belongs to the picked
// session. tmux pane ids are a per-server counter that restarts from %0 on a
// fresh server, so a stale id from a since-replaced server can collide with
// an unrelated live pane. Whenever the roster can name the session's actual
// process, its pane is re-derived by walking that process's ancestry instead
// -- an identity check PaneExists cannot offer -- and the ledger column is
// used as-is only when the roster has nothing to check identity against.
func TestReachablePane(t *testing.T) {
	live := []roster.Agent{{SessionID: "live", PID: 200, Kind: "interactive"}}
	dup := []roster.Agent{
		{SessionID: "dup", PID: 200, Kind: "interactive"},
		{SessionID: "dup", PID: 201, Kind: "interactive"},
	}

	cases := []struct {
		name       string
		agents     []roster.Agent
		mux        *fakeMux
		sessionID  string
		ledgerPane string
		want       string
	}{{
		// Gate (a): once the roster names the session's process, its
		// identity-verified pane wins even over a ledger pane that also
		// exists on this server -- the ledger id may be an unrelated pane
		// that happens to collide.
		name:       "roster-verified pane wins over a live ledger pane",
		agents:     live,
		mux:        &fakeMux{panes: map[string]bool{"%3": true}, find: map[int]string{200: "%7"}},
		sessionID:  "live",
		ledgerPane: "%3",
		want:       "%7",
	}, {
		name:       "stale ledger pane falls back to re-resolution",
		agents:     live,
		mux:        &fakeMux{find: map[int]string{200: "%7"}},
		sessionID:  "live",
		ledgerPane: "%3",
		want:       "%7",
	}, {
		// The roster names the process but its ancestry resolves to no pane
		// at all (e.g. it lives on another server). Even though the ledger id
		// happens to exist on this server, it must not be trusted: the roster
		// already had identity to check and it did not confirm this pane.
		name:       "ledger pane collision with an unrelated live pane is not trusted",
		agents:     live,
		mux:        &fakeMux{panes: map[string]bool{"%3": true}},
		sessionID:  "live",
		ledgerPane: "%3",
		want:       "",
	}, {
		name:      "empty ledger pane re-resolves",
		agents:    live,
		mux:       &fakeMux{find: map[int]string{200: "%7"}},
		sessionID: "live",
		want:      "%7",
	}, {
		// Gate (b): the ledger pane is the fallback of last resort, used only
		// when the roster has no entry for this session to check identity
		// against.
		name:       "session absent from roster falls back to the ledger pane",
		agents:     live,
		mux:        &fakeMux{panes: map[string]bool{"%9": true}},
		sessionID:  "gone",
		ledgerPane: "%9",
		want:       "%9",
	}, {
		name:       "session absent from roster and ledger pane not on this server",
		agents:     live,
		mux:        &fakeMux{},
		sessionID:  "gone",
		ledgerPane: "%9",
		want:       "",
	}, {
		// A roster entry duplicated under two pids (see Target.RosterMatches)
		// must not stop pane resolution at the first pid tried.
		name:      "duplicate roster entries try every pid for a pane",
		agents:    dup,
		mux:       &fakeMux{find: map[int]string{201: "%8"}},
		sessionID: "dup",
		want:      "%8",
	}, {
		// Nothing to look the process up by, and an empty pane column: the row
		// is not reachable by any pane.
		name:       "no session id and no ledger pane",
		agents:     live,
		mux:        &fakeMux{find: map[int]string{200: "%7"}},
		ledgerPane: "",
		want:       "",
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := reachablePane(c.mux, c.agents, c.sessionID, c.ledgerPane); got != c.want {
				t.Errorf("reachablePane = %q, want %q", got, c.want)
			}
		})
	}
}

// The re-derived pane has to reach DecideAction as if it had come from the
// ledger, so the pick lands on the switch path rather than on a resume that
// would kill a session whose pane is right here.
func TestReachablePaneRoutesToSwitch(t *testing.T) {
	agents := []roster.Agent{{SessionID: testUUID, PID: 200, Kind: "interactive"}}
	mux := &fakeMux{find: map[int]string{200: "%7"}}

	tgt := resumable()
	tgt.InRoster, tgt.Kind, tgt.PID, tgt.Origin = true, "interactive", 200, originOrphan
	tgt.Pane = reachablePane(mux, agents, testUUID, "%stale")

	if act := DecideAction(tgt); act.Kind != "switch" || act.Pane != "%7" {
		t.Errorf("DecideAction with a re-derived pane = %+v, want switch to %%7", act)
	}
}

// The wait after a SIGTERM is what keeps a resume from opening a transcript the
// dying process is still flushing. It has to be sure the session ended, so an
// unreadable roster counts as "still there" rather than as "gone".
func TestWaitGone(t *testing.T) {
	present := []roster.Agent{{SessionID: "s", PID: 1}}
	rosterErr := errors.New("claude agents --json: exit 1")

	t.Run("absent immediately", func(t *testing.T) {
		ticks := 0
		ok := waitGone("s", func() ([]roster.Agent, error) { return nil, nil }, func() { ticks++ }, 5)
		if !ok || ticks != 1 {
			t.Errorf("got (%v, %d ticks), want (true, 1 tick)", ok, ticks)
		}
	})

	t.Run("leaves partway through", func(t *testing.T) {
		reads := 0
		list := func() ([]roster.Agent, error) {
			reads++
			if reads < 3 {
				return present, nil
			}
			return nil, nil
		}
		if !waitGone("s", list, func() {}, 5) {
			t.Error("waitGone = false, want true once the session leaves the roster")
		}
	})

	t.Run("never leaves", func(t *testing.T) {
		ticks := 0
		ok := waitGone("s", func() ([]roster.Agent, error) { return present, nil }, func() { ticks++ }, 4)
		if ok || ticks != 4 {
			t.Errorf("got (%v, %d ticks), want (false, 4 ticks)", ok, ticks)
		}
	})

	t.Run("unreadable roster is not proof of death", func(t *testing.T) {
		if waitGone("s", func() ([]roster.Agent, error) { return nil, rosterErr }, func() {}, 3) {
			t.Error("waitGone = true on an unreadable roster, want false")
		}
	})

	// Another session leaving does not stand in for this one.
	t.Run("other sessions do not count", func(t *testing.T) {
		other := []roster.Agent{{SessionID: "t", PID: 2}}
		if !waitGone("s", func() ([]roster.Agent, error) { return other, nil }, func() {}, 2) {
			t.Error("waitGone = false when only another session is listed, want true")
		}
	})
}
