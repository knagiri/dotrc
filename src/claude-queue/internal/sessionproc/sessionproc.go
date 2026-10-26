// Package sessionproc finds and ends the process behind a live session: the
// tmux pane an interactive session runs in, and the SIGTERM-and-wait that ends
// it without racing its transcript flush.
//
// The picker needs both to switch to or resume a session, and hibernation
// needs both to stop one, so they live here rather than in either caller.
package sessionproc

import (
	"fmt"
	"syscall"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// PaneForSession is the process-tree lookup itself, taking the pane finder as
// an argument so the roster-to-pane wiring can be tested without tmux.
//
// It tries every roster entry for sessionID, not just the first: `claude
// agents --json` has been observed to list the same session id twice, and
// stopping at the first entry risks missing the one pid that actually resolves
// to a pane.
//
// Background agents are skipped rather than looked up, because the ancestry
// walk is only meaningful for a process that was started inside a pane. A
// background agent is not: it is forked by the host-shared `claude daemon run`
// singleton, and that daemon is itself a descendant of whichever process first
// needed it. When that happened to be inside a pane, every background agent
// under the daemon walks up into that pane -- and since the daemon is shared
// across worktrees, unrelated sessions resolve to the same one. Acting on such
// a pane would reach a third session's window with no error.
func PaneForSession(agents []roster.Agent, sessionID string, find func(int) (string, bool)) string {
	for _, a := range AgentsFor(agents, sessionID) {
		if a.Kind == roster.KindBackground {
			continue
		}
		if pane, found := find(a.PID); found {
			return pane
		}
	}
	// The session is live but has no pane of ours: an interactive session that
	// outlived the server it started in, or a background agent, which never had
	// one.
	return ""
}

// AgentsFor returns every roster entry for sessionID. Session ids are not
// guaranteed unique there, so callers that act on identity (pane resolution,
// kill, resume) need to see all of them rather than assume the first is the
// only one.
func AgentsFor(agents []roster.Agent, sessionID string) []roster.Agent {
	if sessionID == "" {
		return nil
	}
	var matches []roster.Agent
	for _, a := range agents {
		if a.SessionID == sessionID {
			matches = append(matches, a)
		}
	}
	return matches
}

// pollAttempts and pollInterval bound the wait for a SIGTERM'd session to
// leave the roster: 10s in half-second steps. Claude flushes its transcript on
// the way out, so resuming before it is gone would reopen a half-written
// conversation -- and would also be the two-processes-one-transcript state the
// kill exists to avoid.
const (
	pollAttempts = 20
	pollInterval = 500 * time.Millisecond
)

// End asks pid to exit and waits for cfgDir's roster to stop listing
// sessionID.
//
// SIGTERM only, never SIGKILL: a session that ignores the signal is a session
// still holding its transcript, and forcing it out risks losing the very
// conversation a later resume would recover. Giving up is the conservative
// answer -- the process and the transcript stay intact for a person to decide
// about.
func End(pid int, sessionID, cfgDir string) error {
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		return fmt.Errorf("SIGTERM to pid %d: %w", pid, err)
	}
	list := func() ([]roster.Agent, error) { return roster.ListIn(cfgDir) }
	if !WaitGone(sessionID, list, func() { time.Sleep(pollInterval) }, pollAttempts) {
		return fmt.Errorf("session %s is still in the roster after SIGTERM to pid %d", short(sessionID), pid)
	}
	return nil
}

// WaitGone polls until the roster stops listing sessionID, with the roster
// read and the sleep injected so the loop is testable without a process to
// kill.
//
// A roster that cannot be read counts as "still there": it is not evidence the
// session ended, and the whole point of the wait is to be sure it did.
func WaitGone(sessionID string, list func() ([]roster.Agent, error), tick func(), attempts int) bool {
	for i := 0; i < attempts; i++ {
		tick()
		agents, err := list()
		if err != nil {
			continue
		}
		if len(AgentsFor(agents, sessionID)) == 0 {
			return true
		}
	}
	return false
}

func short(sessionID string) string {
	if len(sessionID) > 8 {
		return sessionID[:8]
	}
	return sessionID
}
