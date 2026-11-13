package db

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// concurrentOpens runs rounds of workers goroutines that each Open path,
// write one row and Close, the shape of hooks firing for events that arrive
// together, and returns every error any of them hit.
func concurrentOpens(t *testing.T, path string, workers, rounds int) []error {
	t.Helper()
	var (
		mu   sync.Mutex
		errs []error
	)
	for r := 0; r < rounds; r++ {
		var wg sync.WaitGroup
		for w := 0; w < workers; w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				err := func() error {
					conn, err := Open(path)
					if err != nil {
						return err
					}
					defer conn.Close()
					_, err = conn.Exec(
						"INSERT INTO sessions(session_id) VALUES (?) ON CONFLICT DO NOTHING", "s",
					)
					return err
				}()
				if err != nil {
					mu.Lock()
					errs = append(errs, err)
					mu.Unlock()
				}
			}()
		}
		wg.Wait()
	}
	return errs
}

func TestOpenConcurrent(t *testing.T) {
	for _, tc := range []struct {
		name string
		init bool
		// stale, if set, runs on the initialized database to make it look like
		// one written by an older binary.
		stale []string
	}{
		{"fresh database", false, nil},
		{"initialized database", true, nil},
		// A column added since the database was written: every Open sees it
		// missing at once, and only one may add it.
		{"old schema database", true, []string{
			"DROP VIEW queue",
			"ALTER TABLE session_links DROP COLUMN pr",
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "test.db")
			if tc.init {
				conn, err := Open(path)
				if err != nil {
					t.Fatalf("Open: %v", err)
				}
				for _, q := range tc.stale {
					if _, err := conn.Exec(q); err != nil {
						t.Fatalf("%s: %v", q, err)
					}
				}
				conn.Close()
			}
			errs := concurrentOpens(t, path, 8, 40)
			for i, err := range errs {
				if i == 5 {
					t.Errorf("... %d more", len(errs)-i)
					break
				}
				t.Errorf("concurrent Open: %v", err)
			}
		})
	}
}

// TestOpenPragmasOnEveryConnection checks the PRAGMAs reach every connection
// the pool hands out, not only the one that happened to run them.
func TestOpenPragmasOnEveryConnection(t *testing.T) {
	conn, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	ctx := context.Background()
	for i := 0; i < 3; i++ {
		// Held open so the next Conn has to be a different connection.
		c, err := conn.Conn(ctx)
		if err != nil {
			t.Fatalf("Conn %d: %v", i, err)
		}
		defer c.Close()

		var busy, fk int
		var jm string
		if err := c.QueryRowContext(ctx, "PRAGMA busy_timeout").Scan(&busy); err != nil {
			t.Fatalf("conn %d busy_timeout: %v", i, err)
		}
		if err := c.QueryRowContext(ctx, "PRAGMA foreign_keys").Scan(&fk); err != nil {
			t.Fatalf("conn %d foreign_keys: %v", i, err)
		}
		if err := c.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&jm); err != nil {
			t.Fatalf("conn %d journal_mode: %v", i, err)
		}
		if busy != 5000 || fk != 1 || jm != "wal" {
			t.Errorf("conn %d: busy_timeout=%d foreign_keys=%d journal_mode=%s, want 5000 1 wal", i, busy, fk, jm)
		}
	}
}

func TestOpenRecreatesChangedView(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")
	conn, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := conn.Exec("DROP VIEW queue"); err != nil {
		t.Fatalf("drop view: %v", err)
	}
	if _, err := conn.Exec("CREATE VIEW queue AS SELECT session_id FROM sessions"); err != nil {
		t.Fatalf("create old view: %v", err)
	}
	conn.Close()

	conn, err = Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer conn.Close()
	var got string
	if err := conn.QueryRow(
		"SELECT sql FROM sqlite_master WHERE type = 'view' AND name = 'queue'",
	).Scan(&got); err != nil {
		t.Fatalf("read view: %v", err)
	}
	if got != View {
		t.Errorf("view not recreated; stored definition:\n%s", got)
	}
	// The new definition's columns are there.
	if _, err := conn.Exec("SELECT effective_state, activity_at FROM queue"); err != nil {
		t.Errorf("query new view: %v", err)
	}
}

func TestOpenPathWithURIReservedChars(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "a b?c#d%e")
	path := filepath.Join(dir, "test.db")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	conn, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	conn.Close()
	if _, err := os.Stat(path); err != nil {
		t.Errorf("database not created at %q: %v", path, err)
	}
}

// TestOpenLeavesCurrentViewAlone checks that an Open of a database whose view
// already matches does not rewrite the schema: schema_version moves on any
// DROP/CREATE, so a rebuild on every Open would show up here.
func TestOpenLeavesCurrentViewAlone(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")
	version := func() int {
		conn, err := Open(path)
		if err != nil {
			t.Fatalf("Open: %v", err)
		}
		defer conn.Close()
		var v int
		if err := conn.QueryRow("PRAGMA schema_version").Scan(&v); err != nil {
			t.Fatalf("schema_version: %v", err)
		}
		return v
	}
	first := version()
	if second := version(); second != first {
		t.Errorf("schema_version %d -> %d across a reopen; the view was rebuilt", first, second)
	}
}
