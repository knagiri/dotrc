package watch

import (
	"bytes"
	"database/sql"
	"errors"
	"io"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/hibernate"
	"github.com/knagiri/dotrc/src/claude-queue/internal/reconcile"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

const dir = "/home/x/.claude"

var now = time.Unix(1_800_000_000, 0)

// ledger holds two running sessions idle for 3h: one the roster reports idle,
// one it reports busy.
func ledger(t *testing.T) *sql.DB {
	t.Helper()
	conn, err := db.Open(filepath.Join(t.TempDir(), "q.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	for _, id := range []string{"idleidle-1", "busybusy-1"} {
		if _, err := conn.Exec("INSERT INTO sessions(session_id, config_dir, transcript_path) VALUES (?, ?, '/t.jsonl')", id, dir); err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Exec("INSERT INTO events(session_id, event_type, state, created_at) VALUES (?, 'Stop', 'idle_done', ?)", id, now.Unix()-3*3600); err != nil {
			t.Fatal(err)
		}
	}
	return conn
}

type calls struct {
	sweeps     int
	prWatches  int
	resumed    map[string]bool
	hibernated []string
	checked    []string
}

func (c *calls) deps(hibernateErr error) Deps {
	return Deps{
		Sweep: func(*sql.DB) (reconcile.Result, error) {
			c.sweeps++
			return reconcile.Result{Closed: 1}, nil
		},
		List: func(string) ([]roster.Agent, error) {
			return []roster.Agent{
				{SessionID: "idleidle-1", PID: 1 << 30, Kind: roster.KindBackground, Status: roster.StatusIdle},
				{SessionID: "busybusy-1", PID: 1 << 30, Kind: roster.KindBackground, Status: "busy"},
			}, nil
		},
		LastTurnSendsMessage: func(string) (bool, error) { return false, nil },
		Hibernate: func(cand hibernate.Candidate) error {
			c.hibernated = append(c.hibernated, cand.SessionID)
			return hibernateErr
		},
		Check: func(cand hibernate.Candidate) error {
			c.checked = append(c.checked, cand.SessionID)
			return hibernateErr
		},
		PRWatch: func(*sql.DB, time.Time, time.Duration, io.Writer) map[string]bool {
			c.prWatches++
			return c.resumed
		},
		Now: func() time.Time { return now },
	}
}

// The reconcile and the stop both land on the stubs on the pass's own path,
// which is what lets the dry-run test below trust a zero count.
func TestWatch_StubsCatchEveryEffect(t *testing.T) {
	c := &calls{}
	var out bytes.Buffer
	Pass(ledger(t), Options{Idle: 2 * time.Hour}, c.deps(nil), &out)
	if c.sweeps != 1 || c.prWatches != 1 || len(c.hibernated) != 1 || c.hibernated[0] != "idleidle-1" {
		t.Fatalf("sweeps = %d, PR watches = %d, hibernated = %v; output:\n%s", c.sweeps, c.prWatches, c.hibernated, &out)
	}
	for _, want := range []string{"reconcile: closed 1", "hibernated idleidle (background, idle 3h)", "skipped busybusy: roster status is \"busy\""} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("output lacks %q:\n%s", want, &out)
		}
	}
}

func TestWatch_DryRunStopsNothing(t *testing.T) {
	c := &calls{}
	var out bytes.Buffer
	Pass(ledger(t), Options{Idle: 2 * time.Hour, DryRun: true}, c.deps(nil), &out)
	if c.sweeps != 0 || c.prWatches != 0 || len(c.hibernated) != 0 {
		t.Fatalf("dry run: sweeps = %d, PR watches = %d, hibernated = %v", c.sweeps, c.prWatches, c.hibernated)
	}
	if !strings.Contains(out.String(), "would hibernate idleidle") || len(c.checked) != 1 {
		t.Fatalf("dry run did not check and report the candidate (checked %v):\n%s", c.checked, &out)
	}
	// A dry run reports the pane-level skips too, from the read-only check.
	out.Reset()
	Pass(ledger(t), Options{Idle: 2 * time.Hour, DryRun: true}, (&calls{}).deps(&hibernate.SkipError{Reason: "pane %5 is on screen"}), &out)
	if !strings.Contains(out.String(), "skipped idleidle: pane %5 is on screen") {
		t.Fatalf("dry run did not report the check's skip:\n%s", &out)
	}
}

func TestWatch_ReportsSkipsAndFailures(t *testing.T) {
	var out bytes.Buffer
	Pass(ledger(t), Options{Idle: 2 * time.Hour}, (&calls{}).deps(&hibernate.SkipError{Reason: "pane %5 is on screen"}), &out)
	if !strings.Contains(out.String(), "skipped idleidle: pane %5 is on screen") {
		t.Fatalf("skip not reported:\n%s", &out)
	}
	out.Reset()
	Pass(ledger(t), Options{Idle: 2 * time.Hour}, (&calls{}).deps(errors.New("still in the roster")), &out)
	if !strings.Contains(out.String(), "failed idleidle: still in the roster") {
		t.Fatalf("failure not reported:\n%s", &out)
	}
}

// A session the PR watch has just resumed is idle by its old idle_done event
// until its first hook lands, and must not be stopped again in the same pass.
func TestWatch_ResumedSessionNotHibernated(t *testing.T) {
	c := &calls{resumed: map[string]bool{"idleidle-1": true}}
	var out bytes.Buffer
	Pass(ledger(t), Options{Idle: 2 * time.Hour}, c.deps(nil), &out)
	if len(c.hibernated) != 0 {
		t.Fatalf("hibernated %v right after the PR watch woke it:\n%s", c.hibernated, &out)
	}
	if !strings.Contains(out.String(), "skipped idleidle: woken by the PR watch in this pass") {
		t.Errorf("skip not reported:\n%s", &out)
	}
}
