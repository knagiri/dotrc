// Package reconcile closes ledger rows whose sessions are no longer running.
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
package reconcile

import (
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
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

// roster returns the session ids reported by `claude agents --json`.
func roster() ([]string, error) {
	out, err := exec.Command("claude", "agents", "--json").Output()
	if err != nil {
		return nil, fmt.Errorf("claude agents --json: %w", err)
	}
	var agents []struct {
		SessionID string `json:"sessionId"`
	}
	if err := json.Unmarshal(out, &agents); err != nil {
		return nil, fmt.Errorf("parse roster: %w", err)
	}
	ids := make([]string, 0, len(agents))
	for _, a := range agents {
		if a.SessionID != "" {
			ids = append(ids, a.SessionID)
		}
	}
	return ids, nil
}

// Sweep matches the ledger against the live roster and terminates every tracked
// session the roster does not list, returning how many were closed.
//
// A roster that cannot be read is returned as an error with a zero count, never
// as an empty roster: "claude agents failed" is not evidence that anything
// died, and treating it as one would terminate every tracked session at once.
// Callers are expected to skip the pass on error rather than fail.
func Sweep(conn *sql.DB) (int, error) {
	live, err := roster()
	if err != nil {
		return 0, err
	}
	tracked, err := db.LiveSessionIDs(conn)
	if err != nil {
		return 0, err
	}
	closed := 0
	for _, id := range ToClose(tracked, live) {
		if err := db.TerminateSession(conn, id); err != nil {
			return closed, err
		}
		closed++
	}
	return closed, nil
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

	n, err := Sweep(conn)
	if err != nil {
		fmt.Fprintln(os.Stderr, "reconcile: skipped:", err)
		return
	}
	fmt.Fprintf(os.Stderr, "reconcile: closed %d session(s) missing from the roster\n", n)
}
