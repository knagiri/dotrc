// Package done implements `claude-queue done <session-id>`, which declares a
// session's work finished: it leaves the picker's listing, its delegates go
// with it (db.MarkDone), and the GC may collect it a week later. It is the
// picker's done key, and what bin/claude-stop-bg writes before it stops a
// background session -- `claude stop` ends with the same SessionEnd reason as a
// reboot, so the ledger cannot tell from the hook alone.
package done

import (
	"database/sql"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// Run is the CLI entrypoint. It exits 1 on a bad argument, an id that does not
// resolve to exactly one session, or a failed write. Marking a session that is
// already done succeeds: the session is in the state asked for. Taking a done
// back is `claude-queue reopen` (internal/reopen).
func Run(args []string) {
	if len(args) != 1 || args[0] == "" {
		fmt.Fprintln(os.Stderr, "usage: claude-queue done <session-id-or-prefix>")
		os.Exit(1)
	}
	conn, err := db.Open(db.DefaultPath())
	if err != nil {
		fmt.Fprintln(os.Stderr, "done:", err)
		os.Exit(1)
	}
	err = run(conn, args[0], time.Now().Unix(), os.Stdout)
	conn.Close()
	if err != nil {
		fmt.Fprintln(os.Stderr, "done:", err)
		os.Exit(1)
	}
}

// run resolves prefix and marks it done, reporting on out. Split from Run so it
// can be driven against a test database without an os.Exit.
func run(conn *sql.DB, prefix string, now int64, out io.Writer) error {
	id, err := db.ResolveSessionID(conn, prefix)
	if err != nil {
		return err
	}
	var wasDone bool
	if err := conn.QueryRow(
		"SELECT done_at IS NOT NULL FROM sessions WHERE session_id = ?", id,
	).Scan(&wasDone); err != nil {
		return fmt.Errorf("read %s: %w", id, err)
	}
	n, err := db.MarkDone(conn, id, now)
	if err != nil {
		return err
	}
	descendants := n
	if !wasDone {
		descendants--
	}
	fmt.Fprintf(out, "done: %s (+%d descendants)\n", id, descendants)
	return nil
}
