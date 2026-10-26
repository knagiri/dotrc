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
// It is authoritative only about ITS OWN config dir, though. The ledger is one
// file per host, while the roster is one per CLAUDE_CONFIG_DIR, so a row is only
// ever compared against the roster of the dir it was recorded under -- reading
// one dir's roster as the full list of live sessions would close every row
// belonging to the others. That is not hypothetical: the picker runs from a tmux
// popup, a non-interactive shell that carries whatever CLAUDE_CONFIG_DIR the
// tmux server was started with, so without this every session under another dir
// would be terminated each time the picker was opened.
package reconcile

import (
	"database/sql"
	"flag"
	"fmt"
	"os"
	"os/exec"

	"github.com/knagiri/dotrc/src/claude-queue/internal/configdir"
	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// ToClose returns the tracked session ids that their own config dir's roster
// does not list, preserving the order of tracked. Split out from the exec and
// SQL around it because this set difference is the entire decision, and it is
// the part worth testing directly.
//
// live maps a config dir to the session ids its roster reported. A dir ABSENT
// from that map is one whose roster could not be read, and its rows are left
// open: an unreadable roster is not evidence that anything ended. A dir present
// with an empty list is the opposite -- a roster that really did report nothing
// running -- and closes every row under it.
func ToClose(tracked []db.LiveSession, live map[string][]string) []string {
	liveSet := make(map[string]map[string]struct{}, len(live))
	for dir, ids := range live {
		set := make(map[string]struct{}, len(ids))
		for _, id := range ids {
			set[id] = struct{}{}
		}
		liveSet[dir] = set
	}
	var out []string
	for _, t := range tracked {
		set, readable := liveSet[t.ConfigDir]
		if !readable {
			continue
		}
		if _, ok := set[t.SessionID]; ok {
			continue
		}
		out = append(out, t.SessionID)
	}
	return out
}

// dirsOf returns the config dirs the tracked rows name, deduplicated and in
// first-seen order, which is the set of rosters a sweep has to read. Only the
// dirs that actually carry a live row: a sweep can never close a row under a dir
// it is not tracking anything in, so asking that dir would cost a subprocess for
// an answer nothing reads.
func dirsOf(tracked []db.LiveSession) []string {
	seen := map[string]struct{}{}
	var out []string
	for _, t := range tracked {
		if _, ok := seen[t.ConfigDir]; ok {
			continue
		}
		seen[t.ConfigDir] = struct{}{}
		out = append(out, t.ConfigDir)
	}
	return out
}

// liveIDsIn returns the session ids the roster of one config dir reports. The
// error from roster.ListIn is passed through untouched: Sweep's contract turns
// on being able to tell "the roster is empty" from "the roster could not be
// read", and that distinction is now per dir.
func liveIDsIn(dir string) ([]string, error) {
	agents, err := roster.ListIn(dir)
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

// Result is what one sweep did: how many rows it closed, how many done-but-
// running background sessions it stopped, and which config dirs it could not
// read -- whose rows it therefore left open, and which a caller can report so
// the omission is visible rather than silent.
type Result struct {
	Closed     int
	Stopped    int
	Unreadable []string
	// StopErrors are the stops that failed, one message each. They do not fail
	// the sweep: the session stays done, and the next sweep tries again.
	StopErrors []string
}

// Sweep matches the ledger against each config dir's live roster and terminates
// every tracked session its own dir's roster does not list, returning what it
// did.
//
// A roster that cannot be read is never treated as an empty one: "claude agents
// failed" is not evidence that anything died, and treating it as one would
// terminate every tracked session under that dir at once. When EVERY dir fails
// the sweep is an error with a zero count, which is what callers already skip
// the pass on; when only some do, the rest are still swept and the failures come
// back in Result.Unreadable.
//
// It then stops every background session whose work is done while its process
// is still running (db.DoneButRunning) -- what a cascade leaves behind when it
// marks a running delegate done. Only a session its own dir's roster lists is
// stopped: an unreadable roster is no evidence it is running, and one the
// roster does not list has just been closed above.
func Sweep(conn *sql.DB) (Result, error) {
	return sweep(conn, liveIDsIn, stopIn)
}

// stopIn stops one background session with `claude stop <short id>` under its
// own config dir, the same way roster.ListIn reads it.
func stopIn(dir, sessionID string) error {
	short := sessionID
	if len(short) > 8 {
		short = short[:8]
	}
	cmd := exec.Command("claude", "stop", short)
	if dir != "" {
		cmd.Env = configdir.Env(os.Environ(), dir)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("claude stop %s: %w: %s", short, err, out)
	}
	return nil
}

// sweep is Sweep with the roster read and the stop injected, so the decisions
// can be tested without a claude binary.
func sweep(conn *sql.DB, list func(dir string) ([]string, error), stop func(dir, sessionID string) error) (Result, error) {
	tracked, err := db.LiveSessions(conn)
	if err != nil {
		return Result{}, err
	}
	dirs := dirsOf(tracked)

	live := make(map[string][]string, len(dirs))
	var res Result
	var firstErr error
	for _, dir := range dirs {
		ids, err := list(dir)
		if err != nil {
			res.Unreadable = append(res.Unreadable, dir)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		live[dir] = ids
	}
	if len(dirs) > 0 && len(live) == 0 {
		return Result{}, firstErr
	}

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
	for _, s := range leftovers {
		if !listed(live, s) {
			continue
		}
		if err := stop(s.ConfigDir, s.SessionID); err != nil {
			res.StopErrors = append(res.StopErrors, err.Error())
			continue
		}
		res.Stopped++
	}
	return res, nil
}

// listed reports whether s's own config dir's roster, as read this sweep,
// lists it.
func listed(live map[string][]string, s db.LiveSession) bool {
	for _, id := range live[s.ConfigDir] {
		if id == s.SessionID {
			return true
		}
	}
	return false
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
	for _, dir := range res.Unreadable {
		fmt.Fprintf(os.Stderr, "reconcile: roster unreadable for %s: its rows were left open\n", dir)
	}
	for _, e := range res.StopErrors {
		fmt.Fprintln(os.Stderr, "reconcile: stop failed:", e)
	}
	fmt.Fprintf(os.Stderr, "reconcile: closed %d session(s) missing from the roster, stopped %d done background session(s)\n", res.Closed, res.Stopped)
}
