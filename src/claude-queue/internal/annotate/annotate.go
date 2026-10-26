// Package annotate implements `claude-queue memo`, `pin` and `unpin`, which
// write a session's free-text memo and its pin (waiting on something outside
// it, with an optional note). The picker binds them to keys; an agent calls
// them on its own session, which is why the session id defaults to
// CLAUDE_CODE_SESSION_ID -- the id Claude Code puts in the environment of every
// hook and Bash tool call.
package annotate

import (
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// sessionEnv is where Claude Code puts the id of the session a command runs in.
const sessionEnv = "CLAUDE_CODE_SESSION_ID"

var usages = map[string]string{
	"memo":  "usage: claude-queue memo [--session <id>] [--] [<text>]",
	"pin":   "usage: claude-queue pin [--session <id>] [--note <text>]",
	"unpin": "usage: claude-queue unpin [--session <id>]",
}

// errUsage is a malformed command line; Run prints the usage for it.
var errUsage = errors.New("bad usage")

// Run is the CLI entrypoint for cmd (memo, pin or unpin). It exits 1 on a bad
// command line, no session id, an id that does not resolve to exactly one
// session, a done session or a failed write, with the reason on stderr.
func Run(cmd string, args []string) {
	conn, err := db.Open(db.DefaultPath())
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", cmd, err)
		os.Exit(1)
	}
	err = run(conn, cmd, args, os.Getenv, os.Stdout, os.Stderr)
	conn.Close()
	if errors.Is(err, errUsage) {
		fmt.Fprintln(os.Stderr, usages[cmd])
		os.Exit(1)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", cmd, err)
		os.Exit(1)
	}
}

// run is Run against an open database, with the environment and the output
// injected so it can be driven from a test without an os.Exit.
func run(conn *sql.DB, cmd string, args []string, getenv func(string) string, out, errOut io.Writer) error {
	if _, ok := usages[cmd]; !ok {
		return fmt.Errorf("unknown command %q", cmd)
	}
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(errOut)
	session := fs.String("session", "", "session id or 8+ char prefix (default $"+sessionEnv+")")
	var note *string
	if cmd == "pin" {
		fs.Func("note", "what the session is waiting on", func(v string) error { note = &v; return nil })
	}
	if err := fs.Parse(args); err != nil {
		return errUsage
	}
	rest := fs.Args()
	if (cmd == "memo" && len(rest) > 1) || (cmd != "memo" && len(rest) > 0) {
		return errUsage
	}

	prefix := *session
	if prefix == "" {
		prefix = getenv(sessionEnv)
	}
	if prefix == "" {
		fmt.Fprintf(errOut, "%s: no --session and $%s is not set\n", cmd, sessionEnv)
		return errUsage
	}
	id, err := db.ResolveSessionID(conn, prefix)
	if err != nil {
		return err
	}

	switch cmd {
	case "memo":
		if len(rest) == 0 {
			m, err := db.Memo(conn, id)
			if err != nil {
				return err
			}
			if m != "" {
				fmt.Fprintln(out, m)
			}
			return nil
		}
		return db.SetMemo(conn, id, rest[0])
	case "pin":
		return db.SetPin(conn, id, note)
	default:
		return db.ClearPin(conn, id)
	}
}
