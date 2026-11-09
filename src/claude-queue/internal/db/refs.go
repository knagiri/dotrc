package db

import (
	"database/sql"
	"fmt"
	"sort"
	"strings"
)

// TreeRefs maps every member of a delegation tree, by 8-char short id, to the
// PRs and branches of the whole tree: "#<pr> <branch>" (or "<branch>" while no
// PR is known) per link, oldest link first, joined by two spaces. Every member
// of a tree maps to the same string.
//
// A tree is everything reachable from its root, the member with no link of its
// own -- done delegates and delegates of delegates included, since the PR may
// well have been made by one of those. A (repo, branch) that appears on several
// links (a delegate re-delegated to answer a review) is shown once, with its PR
// if any of them has one. A tree with no branch on any link has no entry.
//
// Links are walked with a visited set, so a ledger whose links loop -- which
// nothing writes, but nothing forbids either -- still terminates; the loop is
// then rooted at its smallest short id.
func TreeRefs(conn *sql.DB) (map[string]string, error) {
	rows, err := conn.Query(`
		SELECT child_short, parent_session_id, COALESCE(repo, ''), COALESCE(branch, ''), pr
		FROM session_links ORDER BY created_at, child_short`)
	if err != nil {
		return nil, fmt.Errorf("tree refs: %w", err)
	}
	defer rows.Close()

	type link struct {
		child, parent, repo, branch string
		pr                          sql.NullInt64
	}
	var links []link
	parentOf := map[string]string{}
	for rows.Next() {
		var l link
		if err := rows.Scan(&l.child, &l.parent, &l.repo, &l.branch, &l.pr); err != nil {
			return nil, fmt.Errorf("tree refs: %w", err)
		}
		l.parent = shortID(l.parent)
		links = append(links, l)
		parentOf[l.child] = l.parent
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("tree refs: %w", err)
	}

	rootOf := func(s string) string {
		seen := map[string]int{}
		var path []string
		for {
			if i, ok := seen[s]; ok {
				loop := append([]string(nil), path[i:]...)
				sort.Strings(loop)
				return loop[0]
			}
			seen[s] = len(path)
			path = append(path, s)
			p, ok := parentOf[s]
			if !ok {
				return s
			}
			s = p
		}
	}

	type ref struct {
		repo, branch string
		pr           sql.NullInt64
	}
	type tree struct {
		members map[string]bool
		refs    []ref
	}
	trees := map[string]*tree{}
	for _, l := range links {
		root := rootOf(l.child)
		t := trees[root]
		if t == nil {
			t = &tree{members: map[string]bool{root: true}}
			trees[root] = t
		}
		t.members[l.child] = true
		t.members[l.parent] = true
		if l.branch == "" {
			continue
		}
		dup := false
		for i := range t.refs {
			if t.refs[i].repo == l.repo && t.refs[i].branch == l.branch {
				if !t.refs[i].pr.Valid {
					t.refs[i].pr = l.pr
				}
				dup = true
				break
			}
		}
		if !dup {
			t.refs = append(t.refs, ref{l.repo, l.branch, l.pr})
		}
	}

	out := map[string]string{}
	for _, t := range trees {
		if len(t.refs) == 0 {
			continue
		}
		parts := make([]string, len(t.refs))
		for i, r := range t.refs {
			parts[i] = r.branch
			if r.pr.Valid {
				parts[i] = fmt.Sprintf("#%d %s", r.pr.Int64, r.branch)
			}
		}
		v := strings.Join(parts, "  ")
		for m := range t.members {
			out[m] = v
		}
	}
	return out, nil
}

func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}
