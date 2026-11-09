// Package link implements `claude-queue link`, which records that one session
// delegated another. bin/claude-worktree calls it right after `claude --bg`
// returns, so the picker can draw delegations as a tree, marking the delegator
// done cascades to its delegates, and hibernation can tell a delegate whose
// delegator is done or gone.
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

// repoPattern is a GitHub owner/repo, the form gh's --repo takes.
var repoPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)

// linkArgs is a validated `claude-queue link` invocation. Repo and Branch are
// empty when not given.
type linkArgs struct{ Parent, Child, Repo, Branch string }

// parseArgs validates the flags, split out of Run so the rejection rules can be
// tested without a database or an os.Exit.
func parseArgs(args []string, stderr io.Writer) (linkArgs, error) {
	fs := flag.NewFlagSet("link", flag.ContinueOnError)
	fs.SetOutput(stderr)
	p := fs.String("parent", "", "full session id of the delegating session")
	c := fs.String("child", "", "8-char short id of the delegated session")
	r := fs.String("repo", "", "GitHub owner/repo the delegate works in (optional)")
	b := fs.String("branch", "", "branch the delegate works on (optional)")
	if err := fs.Parse(args); err != nil {
		return linkArgs{}, err
	}
	if fs.NArg() > 0 {
		return linkArgs{}, fmt.Errorf("unexpected arguments: %v", fs.Args())
	}
	if *p == "" {
		return linkArgs{}, errors.New("--parent is required")
	}
	if !shortIDPattern.MatchString(*c) {
		return linkArgs{}, fmt.Errorf("--child must be 8 lowercase hex chars, got %q", *c)
	}
	if *r != "" && !repoPattern.MatchString(*r) {
		return linkArgs{}, fmt.Errorf("--repo must be owner/repo, got %q", *r)
	}
	return linkArgs{Parent: *p, Child: *c, Repo: *r, Branch: *b}, nil
}

// Run is the CLI entrypoint for
// `claude-queue link --parent <uuid> --child <short> [--repo <owner/repo>] [--branch <name>]`.
// It exits 1 on invalid arguments or a failed write.
func Run(args []string) {
	a, err := parseArgs(args, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "link:", err)
		os.Exit(1)
	}
	conn, err := db.Open(db.DefaultPath())
	if err != nil {
		fmt.Fprintln(os.Stderr, "link:", err)
		os.Exit(1)
	}
	err = db.LinkSession(conn, a.Child, a.Parent, a.Repo, a.Branch)
	conn.Close()
	if err != nil {
		fmt.Fprintln(os.Stderr, "link:", err)
		os.Exit(1)
	}
}
