// Package watch is `claude-queue watch`: one pass of the unattended upkeep a
// systemd-user timer runs every few minutes. It is not a daemon -- each run
// does its pass and exits.
//
// A pass reconciles the ledger against the live rosters, wakes the sessions
// whose pinned PR has news (see package prwatch), then hibernates the sessions
// that have sat idle past the threshold (see package hibernate). Hibernation
// goes last so that a session woken in this pass is not stopped by it.
package watch

import (
	"database/sql"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/hibernate"
	"github.com/knagiri/dotrc/src/claude-queue/internal/prwatch"
	"github.com/knagiri/dotrc/src/claude-queue/internal/reconcile"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// Options are the knobs of one pass.
type Options struct {
	Idle time.Duration
	// PRDebounce is how long new PR activity is held before it is delivered
	// (prwatch.DefaultDebounce).
	PRDebounce time.Duration
	// DryRun reports what would be hibernated without the pass's own effects:
	// no reconcile (it writes the ledger and stops done background sessions),
	// no PR watch (it resumes sessions and moves their cursors), no stop. It
	// does not keep the database untouched: opening it (db.Open) still
	// recreates the queue view and applies pending migrations.
	DryRun bool
}

// Deps is every effect a pass has, injected so a test reaches neither a
// claude binary nor tmux.
type Deps struct {
	Sweep                func(*sql.DB) (reconcile.Result, error)
	List                 func(dir string) ([]roster.Agent, error)
	LastTurnSendsMessage func(transcriptPath string) (bool, error)
	Hibernate            func(hibernate.Candidate) error
	// Check is Hibernate's read-only half, which a dry run asks instead.
	Check func(hibernate.Candidate) error
	// PRWatch is prwatch.Pass: it returns the sessions it resumed.
	PRWatch func(conn *sql.DB, now time.Time, debounce time.Duration, out io.Writer) map[string]bool
	Now     func() time.Time
}

// RealDeps wires Deps to the real reconcile, rosters, transcripts and stops.
func RealDeps(conn *sql.DB) Deps {
	hd := hibernate.RealDeps(conn)
	return Deps{
		Sweep:                reconcile.Sweep,
		List:                 roster.ListIn,
		LastTurnSendsMessage: hibernate.LastTurnSendsMessage,
		Hibernate:            func(c hibernate.Candidate) error { return hibernate.Hibernate(c, hd) },
		Check:                func(c hibernate.Candidate) error { return hibernate.Check(c, hd) },
		PRWatch: func(conn *sql.DB, now time.Time, debounce time.Duration, out io.Writer) map[string]bool {
			pd := prwatch.RealDeps(hd, func() (map[string]int, error) { return db.RunningDelegateCounts(conn) })
			return prwatch.Pass(conn, now, debounce, pd, out)
		},
		Now: time.Now,
	}
}

// Pass runs one pass and writes one line per thing it did or declined to do.
// Failures are reported in those lines rather than returned: the pass is
// best-effort, and the next one tries again.
func Pass(conn *sql.DB, opts Options, deps Deps, out io.Writer) {
	if opts.DryRun {
		fmt.Fprintln(out, "reconcile: skipped (dry run)")
	} else {
		res, err := deps.Sweep(conn)
		if err != nil {
			fmt.Fprintln(out, "reconcile: failed:", err)
		} else {
			for _, dir := range res.Unreadable {
				fmt.Fprintf(out, "reconcile: roster unreadable for %s: its sessions were left as they are\n", dir)
			}
			for _, e := range res.StopErrors {
				fmt.Fprintln(out, "reconcile: stop failed:", e)
			}
			fmt.Fprintf(out, "reconcile: closed %d, stopped %d done background session(s)\n", res.Closed, res.Stopped)
		}
	}

	resumed := map[string]bool{}
	if opts.DryRun {
		fmt.Fprintln(out, "pr-watch: skipped (dry run)")
	} else {
		resumed = deps.PRWatch(conn, deps.Now(), opts.PRDebounce, out)
	}

	now := deps.Now()
	cands, skips, err := hibernate.Candidates(conn, now.Unix(), opts.Idle, deps.List, deps.LastTurnSendsMessage)
	if err != nil {
		fmt.Fprintln(out, "hibernate: failed:", err)
		return
	}
	for _, s := range skips {
		fmt.Fprintf(out, "skipped %s: %s\n", short(s.SessionID), s.Reason)
	}
	for _, c := range cands {
		if resumed[c.SessionID] {
			fmt.Fprintf(out, "skipped %s: woken by the PR watch in this pass\n", short(c.SessionID))
			continue
		}
		act, done := deps.Hibernate, "hibernated"
		if opts.DryRun {
			act, done = deps.Check, "would hibernate"
		}
		switch err := act(c); {
		case err == nil:
			fmt.Fprintf(out, "%s %s (%s)\n", done, short(c.SessionID), describe(c, now))
		case hibernate.IsSkip(err):
			fmt.Fprintf(out, "skipped %s: %v\n", short(c.SessionID), err)
		default:
			fmt.Fprintf(out, "failed %s: %v\n", short(c.SessionID), err)
		}
	}
}

func describe(c hibernate.Candidate, now time.Time) string {
	s := fmt.Sprintf("%s, idle %s", c.Kind, hibernate.Minutes(now.Sub(time.Unix(c.IdleSince, 0))))
	if c.Orphan {
		s += ", orphan"
	}
	return s
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// Run is the CLI entrypoint for `claude-queue watch`. It exits 0 even when
// parts of the pass failed, so the unit's failed state is not flooded with
// what the next pass will retry; only a ledger that cannot be opened -- a pass
// that could do nothing at all -- exits 1.
func Run(args []string) {
	fs := flag.NewFlagSet("watch", flag.ExitOnError)
	idleMinutes := fs.Int("idle-minutes", int(hibernate.DefaultIdle/time.Minute),
		"hibernate sessions idle at least this many minutes since their idle_done event")
	debounceMinutes := fs.Int("pr-debounce-minutes", int(prwatch.DefaultDebounce/time.Minute),
		"deliver new PR activity once it has been pending at least this many minutes")
	dryRun := fs.Bool("dry-run", false, "report what would be hibernated; change nothing")
	_ = fs.Parse(args)
	if *idleMinutes < 0 || *debounceMinutes < 0 {
		fmt.Fprintln(os.Stderr, "watch: --idle-minutes and --pr-debounce-minutes must not be negative")
		os.Exit(2)
	}

	conn, err := db.Open(db.DefaultPath())
	if err != nil {
		fmt.Fprintln(os.Stderr, "watch: open ledger:", err)
		os.Exit(1)
	}
	defer conn.Close()

	opts := Options{
		Idle:       time.Duration(*idleMinutes) * time.Minute,
		PRDebounce: time.Duration(*debounceMinutes) * time.Minute,
		DryRun:     *dryRun,
	}
	Pass(conn, opts, RealDeps(conn), os.Stdout)
}
