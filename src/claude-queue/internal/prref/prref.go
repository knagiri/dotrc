// Package prref is the part of `claude-queue watch` that finds the PR of each
// delegation: session_links records the repo and branch a delegate was
// started on, and this pass asks gh for that branch's PR and writes its number
// next to them.
package prref

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/prwatch"
)

// Pass looks up the PR of every unresolved (delegator, repo, branch) and
// records the one pickPR chooses. gh is asked once per (repo, branch) however
// many delegators share it. A failed lookup is reported and left for the next
// pass; nothing is written for it. The last line counts what was resolved and
// what is still pending.
func Pass(conn *sql.DB, run prwatch.Runner, out io.Writer) {
	qs, err := db.UnresolvedRefs(conn)
	if err != nil {
		fmt.Fprintln(out, "pr-refs: failed:", err)
		return
	}
	type key struct{ repo, branch string }
	type answer struct {
		data []byte
		err  error
	}
	asked := map[key]answer{}
	resolved, pending := 0, 0
	for _, q := range qs {
		k := key{q.Repo, q.Branch}
		a, ok := asked[k]
		if !ok {
			a.data, a.err = run([]string{"gh", "pr", "list", "--repo", q.Repo, "--head", q.Branch,
				"--state", "all", "--json", "number,createdAt"}, q.Dir)
			asked[k] = a
		}
		if a.err != nil {
			fmt.Fprintf(out, "pr-refs: %s %s: %v\n", q.Repo, q.Branch, a.err)
			pending++
			continue
		}
		pr, found, err := pickPR(a.data, q.Since)
		if err != nil {
			fmt.Fprintf(out, "pr-refs: %s %s: %v\n", q.Repo, q.Branch, err)
			pending++
			continue
		}
		if !found {
			pending++
			continue
		}
		if err := db.SetLinkPR(conn, q.ParentSessionID, q.Repo, q.Branch, pr); err != nil {
			fmt.Fprintf(out, "pr-refs: %s %s: %v\n", q.Repo, q.Branch, err)
			pending++
			continue
		}
		resolved++
	}
	fmt.Fprintf(out, "pr-refs: resolved %d, pending %d\n", resolved, pending)
}

// pickPR chooses, from `gh pr list --json number,createdAt` output, the newest
// PR made at or after since (unix seconds). ok is false when there is none.
func pickPR(data []byte, since int64) (pr int, ok bool, err error) {
	var list []struct {
		Number    int       `json:"number"`
		CreatedAt time.Time `json:"createdAt"`
	}
	if err := json.Unmarshal(data, &list); err != nil {
		return 0, false, fmt.Errorf("parse gh pr list: %w", err)
	}
	var newest time.Time
	for _, p := range list {
		if p.CreatedAt.Unix() < since {
			continue
		}
		if !ok || p.CreatedAt.After(newest) {
			pr, newest, ok = p.Number, p.CreatedAt, true
		}
	}
	return pr, ok, nil
}
