package prwatch

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/knagiri/dotrc/src/claude-queue/internal/configdir"
	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/hibernate"
	"github.com/knagiri/dotrc/src/claude-queue/internal/multiplexer"
	"github.com/knagiri/dotrc/src/claude-queue/internal/picker"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// Deps is every effect a delivery has. Like hibernate.Deps, nothing here is
// ever filled in when missing, so a test that leaves a field nil fails on the
// nil call instead of reaching a real claude or tmux; RealDeps is
// the only place the real ones are wired.
type Deps struct {
	// Poll reads a PR (Poll with GhRunner).
	Poll func(pr, dir string) (Activity, error)
	// Hibernate is how a running session is stopped before it is resumed:
	// the hibernation stop, with all of its re-checks (still idle, still the
	// same idle_done event, its window not on screen).
	Hibernate hibernate.Deps
	// RunningDelegates maps a session to its delegates still running with
	// open work (db.RunningDelegateCounts).
	RunningDelegates func() (map[string]int, error)
	IsFile           func(path string) bool
	IsDir            func(path string) bool
	// SessionName and WindowName place an interactive session's window the
	// way the picker's resume does (picker.SessionName, ResumeWindowName).
	SessionName func(cwd string) string
	WindowName  func(transcript, sessionID string) string
	// SessionExists reports whether the tmux session is already there.
	SessionExists func(name string) bool
	// LastAttachedSession names the session a client was attached to most
	// recently (multiplexer.LastAttachedSession), where the window goes when
	// the repo's own session is not there.
	LastAttachedSession func() (string, error)
	// TmuxServerRunning reports whether a tmux server is up.
	TmuxServerRunning func() bool
	// DaemonRunning reports whether the claude daemon of a config dir is up
	// (DaemonRunning).
	DaemonRunning func(configDir string) (bool, error)
	// Run starts argv in dir with env (the full environment) and waits for it
	// to return: tmux and `claude --bg` both return once the long-lived part
	// is running.
	Run func(argv, env []string, dir string) error
}

// RealDeps wires Deps to gh, the ledger behind hd's LatestEvent, tmux and
// claude.
func RealDeps(hd hibernate.Deps, runningDelegates func() (map[string]int, error)) Deps {
	return Deps{
		Poll:                func(pr, dir string) (Activity, error) { return Poll(pr, dir, GhRunner) },
		Hibernate:           hd,
		RunningDelegates:    runningDelegates,
		IsFile:              func(p string) bool { fi, err := os.Stat(p); return err == nil && fi.Mode().IsRegular() },
		IsDir:               isDir,
		SessionName:         picker.SessionName,
		WindowName:          picker.ResumeWindowName,
		SessionExists:       multiplexer.SessionExists,
		LastAttachedSession: multiplexer.LastAttachedSession,
		TmuxServerRunning: func() bool {
			_, ok := multiplexer.Tmux().ServerPID()
			return ok
		},
		DaemonRunning: DaemonRunning,
		Run: func(argv, env []string, dir string) error {
			cmd := exec.Command(argv[0], argv[1:]...)
			cmd.Env, cmd.Dir = env, dir
			if out, err := cmd.CombinedOutput(); err != nil {
				return fmt.Errorf("%s: %w: %s", argv[0], err, strings.TrimSpace(string(out)))
			}
			return nil
		},
	}
}

// Deliver hands msg to the pinned session p by resuming it with msg as its
// first input: `claude --resume <id> <msg>` in a new tmux window for an
// interactive session, `claude --bg --resume <id> <msg>` for a background one.
// The window goes into the repo's own tmux session (the picker's
// SessionName) when it is there, and otherwise into the session a client was
// attached to last. No session is created: one made from the service would
// carry its environment (see multiplexer.DetachedOpenArgs).
// It returns a hibernate.SkipError (see hibernate.IsSkip) when it decided not
// to act now, which leaves the activity to the next pass.
//
// A running session is not typed into. Whether its input line is empty cannot
// be told from outside: a pane can show a suggested next prompt that nobody
// typed, which capture-pane cannot tell from half-typed text. So a running
// session is first stopped the way hibernation stops it, and then resumed like
// a gone one. The stop is not attempted, and the delivery is skipped, when
//   - the session has delegates still running with open work: one of them is
//     handling the PR right now, and its report needs its delegator alive;
//   - the session is not idle at an idle_done event (it is in a turn, or
//     waiting for an approval);
//   - its window is on screen in an attached client: the person is there, and
//     the PR will still say the same thing when they leave.
//
// The cwd and the transcript are checked before anything is stopped, because
// a resume needs both (the picker's resume does the same check) and a session
// stopped only to fail its resume would be left gone for nothing.
//
// The launch only ever goes into a tmux server or a claude daemon that is
// already running, and is skipped when there is none. Either one, started by
// this pass, would carry the systemd service's environment (no SSH agent, the
// unit's fixed PATH) and hand it on: a claude daemon gives every background
// session it later runs -- every delegate claude-worktree starts while it
// lives -- the environment of whoever started it, and a tmux server gives its
// windows its global environment. So an interactive session waits for a tmux
// server, and a background one for its config dir's daemon, which `claude
// --bg` starts on demand and which exits a few seconds after its last client.
// That also leaves the launch nothing long-lived to start inside the
// service's cgroup, which systemd kills when the pass exits.
//
// For a running session the check is made before it is stopped, and again right
// before the resume: stopping it may have been what let the daemon (background)
// or the tmux server (interactive, if its pane was the last window) exit.
func Deliver(p db.PRPin, msg string, deps Deps) error {
	delegates, err := deps.RunningDelegates()
	if err != nil {
		return &hibernate.SkipError{Reason: fmt.Sprintf("cannot read its delegates: %v", err)}
	}
	if n := delegates[p.SessionID]; n > 0 {
		return &hibernate.SkipError{Reason: fmt.Sprintf("%d delegate(s) still running with open work", n)}
	}
	if p.TranscriptPath == "" || !deps.IsFile(p.TranscriptPath) {
		return &hibernate.SkipError{Reason: fmt.Sprintf("cannot resume: transcript %q is not on disk", p.TranscriptPath)}
	}
	if p.Cwd == "" || !deps.IsDir(p.Cwd) {
		return &hibernate.SkipError{Reason: fmt.Sprintf("cannot resume: working directory %q no longer exists", p.Cwd)}
	}

	background := p.Kind == db.KindBackground
	var c hibernate.Candidate
	if !p.Gone {
		c, err = candidate(p, deps.Hibernate)
		if err != nil {
			return err
		}
		background = c.Kind == roster.KindBackground
	}
	if err := hostUp(p, background, deps); err != nil {
		return err
	}
	if !p.Gone {
		if err := hibernate.Hibernate(c, deps.Hibernate); err != nil {
			if hibernate.IsSkip(err) {
				return err
			}
			return fmt.Errorf("stop before resume: %w", err)
		}
		// Re-check for both kinds: closing an interactive session's pane may
		// have been the last window, which makes tmux exit its server
		// (exit-empty), and the new-window would then start one here.
		if err := hostUp(p, background, deps); err != nil {
			return &hibernate.SkipError{Reason: "stopped, but not resumed: " + err.Error()}
		}
	}

	if background {
		argv := []string{"claude", "--bg", "--resume", p.SessionID, msg}
		return deps.Run(argv, configdir.Env(os.Environ(), p.ConfigDir), p.Cwd)
	}
	name := deps.SessionName(p.Cwd)
	if name == "" || !deps.SessionExists(name) {
		last, err := deps.LastAttachedSession()
		if err != nil {
			return &hibernate.SkipError{Reason: fmt.Sprintf("no tmux session to open the window in: %v", err)}
		}
		name = last
	}
	env, launch := picker.LaunchIn(p.ConfigDir, []string{"claude", "--resume", p.SessionID, msg})
	tmux := append([]string{"tmux"}, multiplexer.DetachedOpenArgs(name, deps.WindowName(p.TranscriptPath, p.SessionID), p.Cwd, env, launch)...)
	return deps.Run(tmux, os.Environ(), p.Cwd)
}

// hostUp returns a SkipError unless what the launch goes into -- the tmux
// server, or the config dir's claude daemon -- is already running.
func hostUp(p db.PRPin, background bool, deps Deps) error {
	if !background {
		if !deps.TmuxServerRunning() {
			return &hibernate.SkipError{Reason: "no tmux server is running (starting one here would give it the service's environment)"}
		}
		return nil
	}
	up, err := deps.DaemonRunning(p.ConfigDir)
	if err != nil {
		return &hibernate.SkipError{Reason: fmt.Sprintf("cannot tell whether the claude daemon of %s is running: %v", p.ConfigDir, err)}
	}
	if !up {
		return &hibernate.SkipError{Reason: fmt.Sprintf("no claude daemon is running for %s (starting one here would give later delegates the service's environment)", p.ConfigDir)}
	}
	return nil
}

// candidate is the hibernate.Candidate that stops the running session p: its
// process from the `claude agents` listing, and its latest idle_done event,
// which hibernation re-checks before it stops anything.
func candidate(p db.PRPin, hd hibernate.Deps) (hibernate.Candidate, error) {
	agents, err := hd.List(p.ConfigDir)
	if err != nil {
		return hibernate.Candidate{}, &hibernate.SkipError{Reason: fmt.Sprintf("cannot read the listing of %s: %v", p.ConfigDir, err)}
	}
	var found []roster.Agent
	for _, a := range agents {
		if a.SessionID == p.SessionID {
			found = append(found, a)
		}
	}
	if len(found) != 1 {
		return hibernate.Candidate{}, &hibernate.SkipError{Reason: fmt.Sprintf("running, but listed %d times in %s", len(found), p.ConfigDir)}
	}
	state, at, ok, err := hd.LatestEvent(p.SessionID)
	if err != nil {
		return hibernate.Candidate{}, &hibernate.SkipError{Reason: fmt.Sprintf("cannot read its latest event: %v", err)}
	}
	if !ok || state != "idle_done" {
		return hibernate.Candidate{}, &hibernate.SkipError{Reason: fmt.Sprintf("running and not idle (latest event %q)", state)}
	}
	return hibernate.Candidate{
		SessionID:      p.SessionID,
		ConfigDir:      p.ConfigDir,
		Kind:           found[0].Kind,
		Cwd:            p.Cwd,
		TranscriptPath: p.TranscriptPath,
		PID:            found[0].PID,
		IdleSince:      at,
	}, nil
}
