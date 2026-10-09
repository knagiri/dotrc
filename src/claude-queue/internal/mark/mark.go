// Package mark implements `claude-queue mark <session_id>`, which toggles the
// manual "waiting" mark the picker shows on a session -- a reply the human is
// waiting on, work parked to come back to. The picker binds it to Tab.
package mark

import (
	"fmt"
	"os"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// Run is the CLI entrypoint. It exits 1 on a missing argument or a failed
// write. An ended or unknown session is a silent no-op (see db.ToggleMark), so
// Tab on a resumable row does nothing rather than fail.
func Run(args []string) {
	if len(args) != 1 || args[0] == "" {
		fmt.Fprintln(os.Stderr, "usage: claude-queue mark <session-id>")
		os.Exit(1)
	}
	conn, err := db.Open(db.DefaultPath())
	if err != nil {
		fmt.Fprintln(os.Stderr, "mark:", err)
		os.Exit(1)
	}
	_, err = db.ToggleMark(conn, args[0])
	conn.Close()
	if err != nil {
		fmt.Fprintln(os.Stderr, "mark:", err)
		os.Exit(1)
	}
}
