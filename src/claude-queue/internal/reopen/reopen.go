// Package reopen implements `claude-queue reopen <session-id>`, which takes a
// done back: the session returns to the picker's listing with its work open.
// It is the picker's ctrl-x on the done list, for a done pressed by mistake.
//
// It does not follow session_links the way done does (db.Reopen): the
// delegates that went done with the session stay done.
package reopen

import (
	"database/sql"
	"fmt"
	"io"
	"os"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// Run is the CLI entrypoint. It exits 1 on a bad argument, an id that does not
// resolve to exactly one session, a session that is not done, or a failed
// write. Unlike done, a repeat fails: reopening an open session is more likely
// a wrong id than a state asked for twice.
func Run(args []string) {
	if len(args) != 1 || args[0] == "" {
		fmt.Fprintln(os.Stderr, "usage: claude-queue reopen <session-id-or-prefix>")
		os.Exit(1)
	}
	conn, err := db.Open(db.DefaultPath())
	if err != nil {
		fmt.Fprintln(os.Stderr, "reopen:", err)
		os.Exit(1)
	}
	err = run(conn, args[0], os.Stdout)
	conn.Close()
	if err != nil {
		fmt.Fprintln(os.Stderr, "reopen:", err)
		os.Exit(1)
	}
}

// run resolves prefix and reopens it, reporting on out. Split from Run so it
// can be driven against a test database without an os.Exit.
func run(conn *sql.DB, prefix string, out io.Writer) error {
	id, err := db.ResolveSessionID(conn, prefix)
	if err != nil {
		return err
	}
	ok, err := db.Reopen(conn, id)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("%s is not done", id)
	}
	fmt.Fprintf(out, "reopened: %s\n", id)
	return nil
}
