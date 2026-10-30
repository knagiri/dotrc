package picker

import (
	"database/sql"
	"flag"
	"fmt"
	"os"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/multiplexer"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// recordJump adds a pick that moved the client to sessionID to the jump
// history (db.PushNav), with the session the picker was opened over as the
// origin. Best-effort: a history that failed to record is no reason to call
// the pick itself a failure.
func recordJump(conn *sql.DB, originPane, sessionID string) {
	origin, err := db.SessionInPane(conn, originPane)
	if err != nil {
		fmt.Fprintln(os.Stderr, "nav history:", err)
	}
	if err := db.PushNav(conn, origin, sessionID); err != nil {
		fmt.Fprintln(os.Stderr, "nav history:", err)
	}
}

// navDeps are walkHistory's side doors, injected so a test can drive the walk
// without a tmux server or a claude binary.
type navDeps struct {
	// Mux answers the pane lookups reachablePane makes.
	Mux multiplexer.Multiplexer
	// List reads the roster of a config dir (roster.ListIn).
	List func(dir string) ([]roster.Agent, error)
	// Switch moves the client to pane.
	Switch func(pane string) error
}

// walkHistory moves the client one step through the jump history: back when
// step is -1, forward when it is +1. curPane is the pane the client is in.
// Reports whether it moved.
//
// Back starts from the cursor entry itself when the client is not in that
// entry's session -- it was moved by hand since -- and from the entry before
// it otherwise. Entries it cannot switch to (the session is gone from the
// ledger, e.g. GC'd; or ended, has no pane, or is the one the client is
// already in) are passed over in the same direction. Only a switch to an existing pane counts: a walk never opens a
// window. It moves the cursor and records nothing.
func walkHistory(conn *sql.DB, step int, curPane string, d navDeps) (bool, error) {
	hist, idx, err := db.NavHistory(conn)
	if err != nil || idx < 0 {
		return false, err
	}
	cur, err := db.SessionInPane(conn, curPane)
	if err != nil {
		return false, err
	}

	i := idx + step
	if step < 0 && cur != hist[idx].SessionID {
		i = idx
	}
	rosters := map[string][]roster.Agent{}
	rosterErr := map[string]error{}
	for ; i >= 0 && i < len(hist); i += step {
		sessionID := hist[i].SessionID
		ledgerPane, dir, found, err := db.NavTarget(conn, sessionID)
		if err != nil {
			return false, err
		}
		if !found {
			continue
		}
		agents, seen := rosters[dir]
		if !seen {
			agents, rosterErr[dir] = d.List(dir)
			rosters[dir] = agents
		}
		pane := reachablePane(d.Mux, agents, sessionID, ledgerPane, rosterErr[dir] == nil)
		if pane == "" || pane == curPane {
			continue
		}
		if err := d.Switch(pane); err != nil {
			return false, fmt.Errorf("switch to %s: %w", pane, err)
		}
		return true, db.SetNavCursor(conn, hist[i].Pos)
	}
	return false, nil
}

// RunNav is the CLI entrypoint for `claude-queue nav back|forward`. It always
// exits 0 once it got as far as asking where to go, so a tmux bind never shows
// an error for an empty history; why it did not move goes to a tmux message.
func RunNav(args []string) {
	fs := flag.NewFlagSet("nav", flag.ExitOnError)
	client := fs.String("client", "", "tmux client to move (#{client_name}); empty is tmux's current client")
	pane := fs.String("pane", "", "pane the client is in (#{pane_id}); empty asks tmux")
	usage := func() {
		fmt.Fprintln(os.Stderr, "usage: claude-queue nav {back|forward} [--client <name>] [--pane <id>]")
		os.Exit(2)
	}
	if len(args) < 1 {
		usage()
	}
	var step int
	switch args[0] {
	case "back":
		step = -1
	case "forward":
		step = 1
	default:
		usage()
	}
	_ = fs.Parse(args[1:])

	conn, err := db.Open(db.DefaultPath())
	if err != nil {
		fmt.Fprintln(os.Stderr, "nav:", err)
		os.Exit(1)
	}
	defer conn.Close()

	mux := multiplexer.Detect()
	curPane := *pane
	if curPane == "" {
		curPane = mux.CurrentPane()
	}
	moved, err := walkHistory(conn, step, curPane, navDeps{
		Mux:    mux,
		List:   roster.ListIn,
		Switch: func(p string) error { return multiplexer.SwitchClient(*client, p) },
	})
	switch {
	case err != nil:
		multiplexer.DisplayMessage(*client, "claude-queue nav: "+err.Error())
	case !moved && step < 0:
		multiplexer.DisplayMessage(*client, "claude-queue: no earlier session to go back to")
	case !moved:
		multiplexer.DisplayMessage(*client, "claude-queue: no later session to go forward to")
	}
}
