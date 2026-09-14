// Package link implements `claude-queue link`, which records that one session
// delegated another. bin/claude-worktree calls it right after `claude --bg`
// returns, so the picker can draw delegations as a tree and claude-reap-bg can
// tell a delegate whose delegator is gone.
package link

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// shortIDPattern is the form `claude --bg` prints in its launch banner, and
// the only form of the child's id claude-worktree ever has.
var shortIDPattern = regexp.MustCompile(`^[0-9a-f]{8}$`)

// parseArgs validates the flags, split out of Run so the rejection rules can be
// tested without a database or an os.Exit.
func parseArgs(args []string, stderr io.Writer) (parent, child string, err error) {
	fs := flag.NewFlagSet("link", flag.ContinueOnError)
	fs.SetOutput(stderr)
	p := fs.String("parent", "", "full session id of the delegating session")
	c := fs.String("child", "", "8-char short id of the delegated session")
	if err := fs.Parse(args); err != nil {
		return "", "", err
	}
	if fs.NArg() > 0 {
		return "", "", fmt.Errorf("unexpected arguments: %v", fs.Args())
	}
	if *p == "" {
		return "", "", errors.New("--parent is required")
	}
	if !shortIDPattern.MatchString(*c) {
		return "", "", fmt.Errorf("--child must be 8 lowercase hex chars, got %q", *c)
	}
	return *p, *c, nil
}

// Run is the CLI entrypoint for `claude-queue link --parent <uuid> --child <short>`.
// It exits 1 on invalid arguments or a failed write.
func Run(args []string) {
	parent, child, err := parseArgs(args, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "link:", err)
		os.Exit(1)
	}
	conn, err := db.Open(db.DefaultPath())
	if err != nil {
		fmt.Fprintln(os.Stderr, "link:", err)
		os.Exit(1)
	}
	err = db.LinkSession(conn, child, parent)
	conn.Close()
	if err != nil {
		fmt.Fprintln(os.Stderr, "link:", err)
		os.Exit(1)
	}
}
