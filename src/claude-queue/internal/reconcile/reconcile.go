// Package reconcile closes ledger rows whose sessions are no longer running,
// and stops the background sessions whose work is done but whose process is
// still up.
//
// Closing a row here moves the process axis only (db.TerminateSession): the
// session becomes gone and stays listed, because a process vanishing says
// nothing about whether its work is finished.
//
// A background session does not end when its turn ends: it sits at `idle`
// waiting for further input and, roughly an hour later, disappears WITHOUT
// firing the SessionEnd hook. Nothing then writes terminated_at, so the row
// stays live forever and the picker keeps offering a session that is not there.
// (Closing a session with `claude stop` does fire SessionEnd, which is why the
// primary path -- the delegator running claude-stop-bg -- needs no sweeping.)
//
// The match itself is pure bookkeeping: `claude agents --json` is the
// authoritative roster of live sessions, so a tracked id the roster does not
// list is gone. There is no heuristic and no threshold, which is what makes it
// safe to run unattended on every picker invocation.
//
// The roster holds only the sessions of the config dir the caller's inherited
// environment points at. It assumes every session in the ledger runs under
// that same dir: with a different CLAUDE_CONFIG_DIR in the tmux server or the
// systemd unit, a session living elsewhere is not in the roster and is judged
// gone.
package reconcile

import (
	"database/sql"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"slices"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// ToClose returns the tracked session ids that the live roster does not list,
// preserving the order of tracked. Split out from the exec and SQL around it
// because this set difference is the entire decision, and it is the part worth
// testing directly.
func ToClose(tracked, live []string) []string {
	liveSet := make(map[string]struct{}, len(live))
	for _, id := range live {
		liveSet[id] = struct{}{}
	}
	var out []string
	for _, id := range tracked {
		if _, ok := liveSet[id]; ok {
			continue
		}
		out = append(out, id)
	}
	return out
}

// liveIDs returns the session ids of the live agent roster. The error from
// roster.List is passed through untouched: Sweep's contract turns on being able
// to tell "the roster is empty" from "the roster could not be read".
func liveIDs() ([]string, error) {
	agents, err := roster.List()
	if err != nil {
		return nil, err
	}
	return sessionIDs(agents), nil
}

// sessionIDs projects the roster onto its session ids, dropping entries that
// carry none -- an id-less agent can never match a tracked row, and letting ""
// through would make it match every row whose id failed to be recorded.
func sessionIDs(agents []roster.Agent) []string {
	ids := make([]string, 0, len(agents))
	for _, a := range agents {
		if a.SessionID != "" {
			ids = append(ids, a.SessionID)
		}
	}
	return ids
}

// Result is what one sweep did: how many rows it closed and how many done-but-
// running background sessions it stopped.
type Result struct {
	Closed  int
	Stopped int
	// StopErrors are the stops that failed, one message each. They do not fail
	// the sweep: the session stays done, and the next sweep tries again.
	StopErrors []string
}

// Sweep matches the ledger against the live roster and terminates every tracked
// session the roster does not list, returning what it did.
//
// A roster that cannot be read is returned as an error with a zero Result,
// never as an empty roster: "claude agents failed" is not evidence that
// anything died, and treating it as one would terminate every tracked session
// at once. Callers skip the pass on error.
//
// It then stops every background session whose work is done while its process
// is still running (db.DoneButRunning) -- what a cascade leaves behind when it
// marks a running delegate done. Only a session the roster lists is stopped:
// one the roster does not list has just been closed above.
func Sweep(conn *sql.DB) (Result, error) {
	return sweep(conn, liveIDs, Stop)
}

// Stop stops one background session with `claude stop <short id>`, under the
// inherited environment like roster.List. It moves the process axis only: the
// stop ends in SessionEnd(reason=other), which the hook records as gone, so
// hibernation uses it too without marking any work done.
func Stop(sessionID string) error {
	short := sessionID
	if len(short) > 8 {
		short = short[:8]
	}
	if out, err := exec.Command("claude", "stop", short).CombinedOutput(); err != nil {
		return fmt.Errorf("claude stop %s: %w: %s", short, err, out)
	}
	return nil
}

// sweep is Sweep with the roster read and the stop injected, so the decisions
// can be tested without a claude binary.
func sweep(conn *sql.DB, list func() ([]string, error), stop func(sessionID string) error) (Result, error) {
	// The ledger is read before the roster, so every tracked row predates the
	// roster snapshot it is judged against. The roster is read once: every
	// decision below is made against that one snapshot.
	tracked, err := db.LiveSessions(conn)
	if err != nil {
		return Result{}, err
	}
	// Every DoneButRunning row has terminated_at IS NULL, so it is in tracked:
	// with nothing tracked there is nothing to close and nothing to stop, and
	// reading the roster would only cost a subprocess (and a skip message
	// where claude is not installed).
	if len(tracked) == 0 {
		return Result{}, nil
	}
	live, err := list()
	if err != nil {
		return Result{}, err
	}

	var res Result
	for _, id := range ToClose(tracked, live) {
		if err := db.TerminateSession(conn, id); err != nil {
			return res, err
		}
		res.Closed++
	}

	leftovers, err := db.DoneButRunning(conn)
	if err != nil {
		return res, err
	}
	for _, id := range leftovers {
		if !slices.Contains(live, id) {
			continue
		}
		if err := stop(id); err != nil {
			res.StopErrors = append(res.StopErrors, err.Error())
			continue
		}
		res.Stopped++
	}
	return res, nil
}

// Run is the CLI entrypoint for `claude-queue reconcile`.
func Run(args []string) {
	fs := flag.NewFlagSet("reconcile", flag.ExitOnError)
	_ = fs.Parse(args)

	conn, err := db.Open(db.DefaultPath())
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return
	}
	defer conn.Close()

	res, err := Sweep(conn)
	if err != nil {
		fmt.Fprintln(os.Stderr, "reconcile: skipped:", err)
		return
	}
	for _, e := range res.StopErrors {
		fmt.Fprintln(os.Stderr, "reconcile: stop failed:", e)
	}
	fmt.Fprintf(os.Stderr, "reconcile: closed %d session(s) missing from the roster, stopped %d done background session(s)\n", res.Closed, res.Stopped)
}
