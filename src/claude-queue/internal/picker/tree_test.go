package picker

import (
	"database/sql"
	"strings"
	"testing"

	"github.com/mattn/go-runewidth"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// priorityOf mirrors the queue view's priorities for the states used here.
var priorityOf = map[string]int{"awaiting_approval": 1, "idle_done": 2, "working": 3, "stale": 5}

// trow builds a live row; parent "" means no link was recorded.
func trow(id, state string, created int64, parent string) db.Row {
	return db.Row{
		SessionID:       id,
		EffectiveState:  state,
		Priority:        priorityOf[state],
		CreatedAt:       created,
		ParentSessionID: sql.NullString{String: parent, Valid: parent != ""},
	}
}

// line is the expected output: a session id and its prefix.
type line struct{ id, prefix string }

func defaultKeep(r db.Row) bool { return db.ListOpts{}.Includes(r.EffectiveState) }

func liveOf(ids ...string) func(string) bool {
	m := map[string]bool{}
	for _, id := range ids {
		m[id] = true
	}
	return func(id string) bool { return m[id] }
}

func TestBuildForest(t *testing.T) {
	cases := []struct {
		name    string
		rows    []db.Row
		inScope func(db.Row) bool
		live    func(string) bool
		ascii   bool
		want    []line
	}{{
		// The default listing hides `working`, and a delegator is usually
		// working while its delegate waits. Pulled back, the delegate stays
		// nested instead of surfacing as a root with a misleading mark.
		name: "working parent is pulled back past the state filter",
		rows: []db.Row{
			trow("P", "working", 100, ""),
			trow("C", "idle_done", 90, "P"),
		},
		live: liveOf("P", "C"),
		want: []line{{"P", ""}, {"C", "└─ "}},
	}, {
		// Pulling back applies to ancestors of listed rows only; with nothing
		// listed there is nothing to hang them from.
		name: "no listed rows means no ancestors either",
		rows: []db.Row{
			trow("P", "working", 100, ""),
			trow("C", "working", 90, "P"),
		},
		live: liveOf("P", "C"),
		want: nil,
	}, {
		// A root's rank is its subtree's most urgent priority, so a grandchild
		// awaiting approval lifts its whole delegation above a root that is
		// itself more urgent than that root.
		name: "subtree priority lifts a root with an awaiting grandchild",
		rows: []db.Row{
			trow("R1", "idle_done", 500, ""),
			trow("R2", "working", 50, ""),
			trow("C", "working", 40, "R2"),
			trow("G", "awaiting_approval", 30, "C"),
		},
		live: liveOf("R1", "R2", "C", "G"),
		want: []line{{"R2", ""}, {"C", "└─ "}, {"G", "   └─ "}, {"R1", ""}},
	}, {
		// Equal priority falls back to the subtree's newest event, then id.
		name: "ties break on newest subtree event, then session id",
		rows: []db.Row{
			trow("A", "idle_done", 100, ""),
			trow("B", "idle_done", 100, ""),
			trow("Z", "idle_done", 10, ""),
			trow("Zc", "idle_done", 900, "Z"),
		},
		live: liveOf("A", "B", "Z", "Zc"),
		want: []line{{"Z", ""}, {"Zc", "└─ "}, {"A", ""}, {"B", ""}},
	}, {
		// The three states of "no parent above": nothing recorded (no mark),
		// parent alive but not listed (↑), parent not alive (✂). Only the last
		// is an orphan.
		name: "orphan, detached and unlinked roots are marked apart",
		rows: []db.Row{
			trow("A", "idle_done", 300, "gone"),
			trow("B", "idle_done", 200, "elsewhere"),
			trow("D", "idle_done", 100, ""),
		},
		live: liveOf("A", "B", "D", "elsewhere"),
		want: []line{{"A", "✂ "}, {"B", "↑ "}, {"D", ""}},
	}, {
		// A parent present in the ledger but cut by the repo filter is alive,
		// so its delegate is detached, not orphaned -- and the repo filter is
		// not undone by the ancestor pull-back.
		name: "parent removed by repo scope is detached",
		rows: []db.Row{
			trow("F", "idle_done", 200, ""),
			trow("E", "idle_done", 100, "F"),
		},
		inScope: func(r db.Row) bool { return r.SessionID != "F" },
		live:    liveOf("E", "F"),
		want:    []line{{"E", "↑ "}},
	}, {
		name: "rails across three levels",
		rows: []db.Row{
			trow("R", "idle_done", 10, ""),
			trow("C1", "idle_done", 90, "R"),
			trow("C2", "idle_done", 50, "R"),
			trow("G1", "idle_done", 80, "C1"),
			trow("G2", "idle_done", 70, "C1"),
			trow("H", "idle_done", 60, "G1"),
			trow("K", "idle_done", 40, "C2"),
		},
		live: liveOf("R", "C1", "C2", "G1", "G2", "H", "K"),
		want: []line{
			{"R", ""},
			{"C1", "├─ "},
			{"G1", "│  ├─ "},
			{"H", "│  │  └─ "},
			{"G2", "│  └─ "},
			{"C2", "└─ "},
			{"K", "   └─ "},
		},
	}, {
		name: "rails across three levels, ascii",
		rows: []db.Row{
			trow("R", "idle_done", 10, ""),
			trow("C1", "idle_done", 90, "R"),
			trow("C2", "idle_done", 50, "R"),
			trow("G1", "idle_done", 80, "C1"),
			trow("G2", "idle_done", 70, "C1"),
			trow("H", "idle_done", 60, "G1"),
			trow("K", "idle_done", 40, "C2"),
			trow("O", "idle_done", 5, "gone"),
			trow("X", "idle_done", 4, "elsewhere"),
		},
		live:  liveOf("R", "C1", "C2", "G1", "G2", "H", "K", "O", "X", "elsewhere"),
		ascii: true,
		want: []line{
			{"R", ""},
			{"C1", "|- "},
			{"G1", "|  |- "},
			{"H", "|  |  `- "},
			{"G2", "|  `- "},
			{"C2", "`- "},
			{"K", "   `- "},
			{"O", "x "},
			{"X", "^ "},
		},
	}, {
		// A and B name each other. The pull-back must terminate, and the
		// cycle is cut deterministically: walking up from A (first by id)
		// returns to A through B, so B's link is the one dropped.
		name: "a link cycle terminates and is cut into a root",
		rows: []db.Row{
			trow("A", "idle_done", 100, "B"),
			trow("B", "working", 90, "A"),
		},
		live: liveOf("A", "B"),
		want: []line{{"B", ""}, {"A", "└─ "}},
	}, {
		name: "a self link is a plain root",
		rows: []db.Row{trow("S", "idle_done", 100, "S")},
		live: liveOf("S"),
		want: []line{{"S", ""}},
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := buildForest(c.rows, forestOpts{
				Keep:       defaultKeep,
				InScope:    c.inScope,
				ParentLive: c.live,
				ASCII:      c.ascii,
			})
			var gotLines []line
			for _, r := range got {
				gotLines = append(gotLines, line{r.Row.SessionID, r.Prefix})
			}
			if len(gotLines) != len(c.want) {
				t.Fatalf("got %d rows %q, want %d %q", len(gotLines), gotLines, len(c.want), c.want)
			}
			for i := range c.want {
				if gotLines[i] != c.want[i] {
					t.Errorf("row %d = %q, want %q (all: %q)", i, gotLines[i], c.want[i], gotLines)
				}
			}
		})
	}
}

// The prefix shares the title column rather than adding one, so the title is
// cut to what the prefix leaves and the column keeps its width.
func TestPrefixedTitle(t *testing.T) {
	var asked int
	got := prefixedTitle("│  └─ ✂ ", func(cols int) string {
		asked = cols
		return strings.Repeat("あ", cols) // over-long on purpose: the reader should get the budget
	})
	if want := titleWidth - runewidth.StringWidth("│  └─ ✂ "); asked != want {
		t.Errorf("title reader got %d columns, want %d", asked, want)
	}
	if !strings.HasPrefix(got, "│  └─ ✂ ") {
		t.Errorf("prefix lost: %q", got)
	}

	if got := prefixedTitle(strings.Repeat("│  ", 20), func(cols int) string {
		if cols != 0 {
			t.Errorf("a prefix wider than the column asked for %d columns, want 0", cols)
		}
		return ""
	}); got != strings.Repeat("│  ", 20) {
		t.Errorf("deep prefix = %q", got)
	}
}

// A prefixed title must not move the hidden columns or the worktree offset:
// the pick reads the session id by index, and the tree glyphs are exactly the
// kind of multi-byte text that would expose a byte-counted pad.
func TestParseSelection_PrefixedTitle(t *testing.T) {
	row := db.Row{
		SessionID:      testUUID,
		TmuxPane:       sql.NullString{String: "%3", Valid: true},
		Cwd:            sql.NullString{String: "/w/tree", Valid: true},
		TranscriptPath: sql.NullString{String: "/t/tree.jsonl", Valid: true},
		EffectiveState: "idle_done",
		CreatedAt:      nowMinus(30),
	}
	for _, prefix := range []string{"│  └─ ", "✂ ", "|  `- ", "x "} {
		title := prefixedTitle(prefix, func(cols int) string { return runewidth.Truncate("委譲先の タイトル", cols, "") })
		line := FormatLine(row, title, "wt", nowUnix(), false)
		fields := strings.Split(line, "\t")
		if w := runewidth.StringWidth(fields[colTitle]); w != titleWidth {
			t.Errorf("%q: title column is %d wide, want %d", prefix, w, titleWidth)
		}
		if !strings.HasPrefix(fields[colTitle], prefix) {
			t.Errorf("%q: title column %q lost its prefix", prefix, fields[colTitle])
		}
		sel, ok := parseSelection(line)
		want := selection{SessionID: testUUID, Pane: "%3", Cwd: "/w/tree", Transcript: "/t/tree.jsonl"}
		if !ok || sel != want {
			t.Errorf("%q: parseSelection = %+v (ok=%v), want %+v", prefix, sel, ok, want)
		}
	}
}
