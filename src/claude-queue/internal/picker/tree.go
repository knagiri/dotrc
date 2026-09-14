package picker

import (
	"sort"

	"github.com/mattn/go-runewidth"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// treeGlyphs are the pieces a row's title prefix is built from: the rules of
// `tree` for nesting, plus the mark a root gets when its recorded parent is not
// in the listing.
type treeGlyphs struct {
	branch   string // this row, more siblings follow
	last     string // this row, last sibling
	pipe     string // an ancestor level with more siblings to follow
	blank    string // an ancestor level that was the last sibling
	detached string // parent is alive but not listed (e.g. another repo)
	orphan   string // parent is not alive: nobody is left to close this session
}

var (
	unicodeTree = treeGlyphs{branch: "├─ ", last: "└─ ", pipe: "│  ", blank: "   ", detached: "↑ ", orphan: "✂ "}
	asciiTree   = treeGlyphs{branch: "|- ", last: "`- ", pipe: "|  ", blank: "   ", detached: "^ ", orphan: "x "}
)

// forestOpts carries the decisions buildForest needs from outside: the state
// and repo filters, and whether a session is alive. They are functions so the
// ledger, git and the filesystem stay in Run.
type forestOpts struct {
	// Keep is the state filter. It picks the rows the user asked to see; their
	// ancestors are listed whether or not they pass it.
	Keep func(db.Row) bool
	// InScope is the repo filter, applied after ancestors are pulled back. nil
	// keeps every row. A pulled-back ancestor left with no child in the listing
	// once this has taken its scope-filtered rows is pruned along with them
	// (see the loop in buildForest).
	InScope func(db.Row) bool
	// ParentLive reports whether the ledger still considers a session running.
	ParentLive func(sessionID string) bool
	ASCII      bool
}

// treeRow is a row in display order with the prefix to put before its title.
type treeRow struct {
	Row    db.Row
	Prefix string
}

// buildForest turns the live rows into display order, nesting each delegated
// session under its delegator.
//
// Ancestors are pulled back past the state filter because a delegator is
// usually `working` while its delegates wait, and the default listing hides
// `working`: filtering them would flatten exactly the trees worth showing. The
// repo filter is applied after that and is not undone, so a row whose parent
// lives in another repo is shown as a root, marked. A pulled-back row left
// with no child in the listing after the repo filter is dropped.
//
// Siblings -- roots included -- are ordered by the most urgent priority in
// their subtree, then its most recent event, then session id, so a delegate
// waiting on approval lifts its whole delegation to the top.
func buildForest(rows []db.Row, o forestOpts) []treeRow {
	byID := make(map[string]db.Row, len(rows))
	for _, r := range rows {
		byID[r.SessionID] = r
	}

	listed := map[string]bool{}
	kept := map[string]bool{}
	for _, r := range rows {
		if !o.Keep(r) {
			continue
		}
		listed[r.SessionID] = true
		kept[r.SessionID] = true
		seen := map[string]bool{r.SessionID: true}
		for cur := r; cur.ParentSessionID.Valid; {
			pid := cur.ParentSessionID.String
			p, ok := byID[pid]
			if !ok || seen[pid] {
				break
			}
			seen[pid] = true
			listed[pid] = true
			cur = p
		}
	}
	if o.InScope != nil {
		for id := range listed {
			if !o.InScope(byID[id]) {
				delete(listed, id)
			}
		}
		// A row that is listed only because it was pulled back is there to hold
		// a child still in the listing. Once the repo filter (or an earlier pass
		// of this same loop) has taken every child it had, it is noise in a
		// listing of this repo's sessions. The check below is by direct child,
		// not full descent: if the repo filter drops an intermediate pulled-back
		// row in one step, a kept row further down no longer saves the row above
		// it, even though that kept row is itself still listed. Dropping one row
		// here can leave its own pulled-back parent childless in turn, so repeat
		// until nothing changes.
		for changed := true; changed; {
			changed = false
			hasChild := map[string]bool{}
			for id := range listed {
				if p := byID[id].ParentSessionID; p.Valid && p.String != id {
					hasChild[p.String] = true
				}
			}
			for id := range listed {
				if !kept[id] && !hasChild[id] {
					delete(listed, id)
					changed = true
				}
			}
		}
	}
	if len(listed) == 0 {
		return nil
	}

	ids := make([]string, 0, len(listed))
	for id := range listed {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	parent := map[string]string{}
	for _, id := range ids {
		if p := byID[id].ParentSessionID; p.Valid && p.String != id && listed[p.String] {
			parent[id] = p.String
		}
	}
	// A link cycle cannot come from claude-worktree (a child is always a new
	// session), but the table does not forbid one. Walk up from each row in id
	// order and cut the link that returns to an id already visited, so the
	// result is a forest and does not depend on map order.
	for _, id := range ids {
		seen := map[string]bool{id: true}
		for cur := id; ; {
			p, ok := parent[cur]
			if !ok {
				break
			}
			if seen[p] {
				delete(parent, cur)
				break
			}
			seen[p] = true
			cur = p
		}
	}

	children := map[string][]string{}
	var roots []string
	for _, id := range ids {
		if p, ok := parent[id]; ok {
			children[p] = append(children[p], id)
		} else {
			roots = append(roots, id)
		}
	}

	minPrio := map[string]int{}
	maxCreated := map[string]int64{}
	var measure func(id string)
	measure = func(id string) {
		r := byID[id]
		mp, mc := r.Priority, r.CreatedAt
		for _, k := range children[id] {
			measure(k)
			if minPrio[k] < mp {
				mp = minPrio[k]
			}
			if maxCreated[k] > mc {
				mc = maxCreated[k]
			}
		}
		minPrio[id], maxCreated[id] = mp, mc
	}
	for _, id := range roots {
		measure(id)
	}
	bySubtree := func(s []string) {
		sort.Slice(s, func(i, j int) bool {
			a, b := s[i], s[j]
			if minPrio[a] != minPrio[b] {
				return minPrio[a] < minPrio[b]
			}
			if maxCreated[a] != maxCreated[b] {
				return maxCreated[a] > maxCreated[b]
			}
			return a < b
		})
	}

	g := unicodeTree
	if o.ASCII {
		g = asciiTree
	}
	out := make([]treeRow, 0, len(ids))
	var walk func(id, rails string, root, last bool)
	walk = func(id, rails string, root, last bool) {
		r := byID[id]
		prefix, childRails := "", ""
		if root {
			prefix = rootMark(r, listed, o.ParentLive, g)
		} else {
			prefix = rails + g.branch
			childRails = rails + g.pipe
			if last {
				prefix = rails + g.last
				childRails = rails + g.blank
			}
		}
		out = append(out, treeRow{Row: r, Prefix: prefix})
		kids := children[id]
		bySubtree(kids)
		for i, k := range kids {
			walk(k, childRails, false, i == len(kids)-1)
		}
	}
	bySubtree(roots)
	for _, id := range roots {
		walk(id, "", true, false)
	}
	return out
}

// rootMark says why a root has no parent above it. No recorded parent is an
// ordinary root and gets nothing; a recorded parent that is listed can only
// mean the link was cut as a cycle, and gets nothing either. Otherwise the
// parent is off the listing, and whether it is still alive separates a session
// merely filtered out of view from an orphan whose delegator can no longer
// close it.
func rootMark(r db.Row, listed map[string]bool, live func(string) bool, g treeGlyphs) string {
	p := r.ParentSessionID
	if !p.Valid || listed[p.String] {
		return ""
	}
	if live(p.String) {
		return g.detached
	}
	return g.orphan
}

// prefixedTitle puts prefix ahead of a title cut to the columns the prefix
// leaves, so the title column keeps its fixed width and the worktree column
// after it starts at the same offset on every row. title receives the column
// budget because the picker's title reader truncates as it reads.
func prefixedTitle(prefix string, title func(cols int) string) string {
	cols := titleWidth - runewidth.StringWidth(prefix)
	if cols < 0 {
		cols = 0
	}
	return prefix + title(cols)
}
