package picker

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/mattn/go-runewidth"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/label"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

func nowUnix() int64         { return 1_800_000_000 }
func nowMinus(d int64) int64 { return nowUnix() - d }

func TestFormatLine_AwaitingApproval(t *testing.T) {
	row := db.Row{
		SessionID:      "s1",
		TmuxPane:       sql.NullString{String: "%1", Valid: true},
		Cwd:            sql.NullString{String: "/home/x/projects/everysteel-api", Valid: true},
		EffectiveState: "awaiting_approval",
		TranscriptPath: sql.NullString{String: "/home/x/.claude/projects/enc/s1.jsonl", Valid: true},
		Payload:        sql.NullString{String: `{"tool_name":"Bash","tool_input":{"command":"pnpm prisma migrate"}}`, Valid: true},
		CreatedAt:      nowMinus(120),
	}
	got := FormatLine(row, "prisma migration", "everysteel-api", nowUnix(), false)
	fields := strings.Split(got, "\t")
	if len(fields) != colCount {
		t.Fatalf("want %d tab-separated fields, got %d: %q", colCount, len(fields), got)
	}
	if fields[colIcon] != "⏳" {
		t.Errorf("icon = %q, want ⏳", fields[colIcon])
	}
	// The title column is padded, so it is compared trimmed here; the padding
	// itself is what TestFormatLine_ColumnWidths is about.
	if got := strings.TrimSpace(fields[colTitle]); got != "prisma migration" {
		t.Errorf("title = %q, want prisma migration", got)
	}
	if got := strings.TrimSpace(fields[colWorktree]); got != "everysteel-api" {
		t.Errorf("worktree = %q, want everysteel-api", got)
	}
	if fields[colAge] != "2m" {
		t.Errorf("age = %q, want 2m", fields[colAge])
	}
	if !strings.Contains(fields[colSummary], "Bash: pnpm prisma migrate") {
		t.Errorf("summary = %q", fields[colSummary])
	}
	if fields[colSessionID] != "s1" {
		t.Errorf("hidden session id = %q, want s1", fields[colSessionID])
	}
	if fields[colPane] != "%1" {
		t.Errorf("hidden tmux_pane = %q, want %%1", fields[colPane])
	}
	if fields[colCwd] != "/home/x/projects/everysteel-api" {
		t.Errorf("hidden cwd = %q, want the full path", fields[colCwd])
	}
	// The resume path refuses to run without a transcript, so the path has to
	// reach the pick through this hidden column.
	if fields[colTranscript] != "/home/x/.claude/projects/enc/s1.jsonl" {
		t.Errorf("hidden transcript_path = %q, want the full path", fields[colTranscript])
	}
}

// The column order itself, asserted once so a reshuffle has to come here
// before it reaches the hidden columns: the summary moved behind the age and
// the title was inserted in front of the worktree, which shifted every hidden
// index by one.
func TestFormatLine_ColumnOrder(t *testing.T) {
	row := db.Row{
		SessionID:      "sid",
		TmuxPane:       sql.NullString{String: "%4", Valid: true},
		Cwd:            sql.NullString{String: "/w/a", Valid: true},
		TranscriptPath: sql.NullString{String: "/t/a.jsonl", Valid: true},
		EffectiveState: "working",
		CreatedAt:      nowMinus(60),
	}
	fields := strings.Split(FormatLine(row, "title", "wt", nowUnix(), true), "\t")
	want := []string{"[*]", "title", "wt", "60s", "working", "sid", "%4", "/w/a", "/t/a.jsonl"}
	if len(fields) != len(want) {
		t.Fatalf("got %d columns, want %d", len(fields), len(want))
	}
	for i, w := range want {
		if got := strings.TrimSpace(fields[i]); got != w {
			t.Errorf("column %d = %q, want %q", i+1, got, w)
		}
	}
}

// The two padded columns exist so the eye can run down them, which only works
// if every row spends the same number of terminal columns on each -- including
// the rows that have nothing to put there.
func TestFormatLine_ColumnWidths(t *testing.T) {
	row := db.Row{SessionID: "s", EffectiveState: "working", CreatedAt: nowMinus(10)}

	cases := []struct {
		name            string
		title, worktree string
	}{{
		name:  "ascii fits",
		title: "picker title column", worktree: "dotrc_queue-picker-title-column",
	}, {
		// Japanese is the common case and every rune of it is two columns, so
		// a byte-counting pad (fmt's "%-40s") would leave these rows short by
		// roughly their own length again.
		name:  "japanese counts double",
		title: "picker の ai-title 列", worktree: "案件_日本語ワークツリー",
	}, {
		// Truncate stops a column short rather than split a double-width rune,
		// so an over-long Japanese title needs the pad measured after the cut.
		name:  "japanese overflows",
		title: strings.Repeat("あ", 40), worktree: strings.Repeat("い", 40),
	}, {
		name:  "ascii overflows",
		title: strings.Repeat("x", 80), worktree: strings.Repeat("y", 80),
	}, {
		// A transcript that could not be titled still holds the column open,
		// or the worktree beside it would start in a different place.
		name:  "empty title still holds its column",
		title: "", worktree: "wt",
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fields := strings.Split(FormatLine(row, c.title, c.worktree, nowUnix(), true), "\t")
			if w := runewidth.StringWidth(fields[colTitle]); w != titleWidth {
				t.Errorf("title column is %d wide, want %d: %q", w, titleWidth, fields[colTitle])
			}
			if w := runewidth.StringWidth(fields[colWorktree]); w != worktreeWidth {
				t.Errorf("worktree column is %d wide, want %d: %q", w, worktreeWidth, fields[colWorktree])
			}
		})
	}
}

// A tab or a newline in a title would shift every hidden column of that row,
// and the pick would then attach to another session or open a window in
// another worktree's directory. label.DisplayTitle strips them at the source;
// this is the picker's own end of that contract, since it is the one that
// depends on it.
func TestFormatLine_TitleCannotBreakTheRow(t *testing.T) {
	row := db.Row{
		SessionID:      "sid",
		Cwd:            sql.NullString{String: "/w/a", Valid: true},
		TranscriptPath: sql.NullString{String: "/t/a.jsonl", Valid: true},
		EffectiveState: "working",
		CreatedAt:      nowMinus(10),
	}
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	line := `{"type":"ai-title","aiTitle":"col1\tcol2\rcol3"}` + "\n"
	if err := os.WriteFile(path, []byte(line), 0600); err != nil {
		t.Fatalf("write transcript: %v", err)
	}

	fields := strings.Split(FormatLine(row, label.DisplayTitle(path, titleWidth), "wt", nowUnix(), true), "\t")
	if len(fields) != colCount {
		t.Fatalf("a title with a tab in it produced %d columns, want %d", len(fields), colCount)
	}
	sel, ok := parseSelection(strings.Join(fields, "\t"))
	if !ok || sel.SessionID != "sid" || sel.Cwd != "/w/a" {
		t.Errorf("hidden columns shifted: %+v (ok=%v)", sel, ok)
	}
}

// The hidden columns are addressed by index and every value in them looks
// valid to the code downstream, so a shifted index does not fail -- it acts on
// another session. The round trip through a line FormatLine actually rendered
// is what catches that.
func TestParseSelection(t *testing.T) {
	row := db.Row{
		SessionID:      testUUID,
		TmuxPane:       sql.NullString{String: "%12", Valid: true},
		Cwd:            sql.NullString{String: "/home/x/ghq/dotrc_wt", Valid: true},
		TranscriptPath: sql.NullString{String: "/home/x/.claude/projects/enc/s.jsonl", Valid: true},
		EffectiveState: "awaiting_approval",
		Payload:        sql.NullString{String: `{"tool_name":"Bash","tool_input":{"command":"go test ./..."}}`, Valid: true},
		CreatedAt:      nowMinus(30),
	}
	line := FormatLine(row, "ai タイトル", "dotrc_wt", nowUnix(), false)

	sel, ok := parseSelection(line)
	if !ok {
		t.Fatalf("parseSelection rejected a line FormatLine rendered: %q", line)
	}
	want := selection{
		SessionID:  testUUID,
		Pane:       "%12",
		Cwd:        "/home/x/ghq/dotrc_wt",
		Transcript: "/home/x/.claude/projects/enc/s.jsonl",
	}
	if sel != want {
		t.Errorf("parseSelection = %+v, want %+v", sel, want)
	}

	// fzf can return an empty selection, and a line from anywhere else is not
	// one the hidden columns can be read off at all.
	if _, ok := parseSelection(""); ok {
		t.Error("parseSelection(\"\") reported success")
	}
	if _, ok := parseSelection("a\tb\tc"); ok {
		t.Error("parseSelection accepted a short line")
	}
}

// --with-nth addresses columns by 1-based position, so inserting a column
// ahead of the hidden ones has to move it too. Getting this wrong does not
// fail either -- it renders the session id and the full cwd as visible text.
func TestFzfShowsExactlyTheVisibleColumns(t *testing.T) {
	if got, want := visibleColumns(), "1,2,3,4,5"; got != want {
		t.Errorf("visibleColumns = %q, want %q", got, want)
	}
	if !slices.Contains(fzfArgs(), "--with-nth=1,2,3,4,5") {
		t.Errorf("fzfArgs = %v, want it to carry --with-nth=1,2,3,4,5", fzfArgs())
	}
	// The list has to stop before the first hidden column, whose contents are
	// paths and ids no one wants in the popup.
	if colSummary+1 != colSessionID {
		t.Errorf("the visible run ends at column %d but the hidden ones start at %d", colSummary+1, colSessionID+1)
	}
}

// A row the ledger has no transcript for still renders; the column is empty,
// which is what resumeBlocked reads as "nothing to resume".
func TestFormatLine_NoTranscript(t *testing.T) {
	row := db.Row{SessionID: "s3", EffectiveState: "idle_done", CreatedAt: nowMinus(10)}
	fields := strings.Split(FormatLine(row, "", "wt", nowUnix(), false), "\t")
	if len(fields) != colCount {
		t.Fatalf("want %d fields, got %d", colCount, len(fields))
	}
	if fields[colTranscript] != "" {
		t.Errorf("hidden transcript_path = %q, want empty", fields[colTranscript])
	}
}

// The visible column names the worktree, which is not the cwd's basename when
// the session was started in a subdirectory. Getting the cwd's basename here
// is the bug this column had: a session recorded under .../src/claude-queue
// showed up as "claude-queue" and could not be found by its worktree name.
func TestFormatLine_DeepCwdShowsWorktree(t *testing.T) {
	const cwd = "/home/x/ghq/github.com/knagiri/dotrc_queue-picker/src/claude-queue"
	row := db.Row{
		SessionID:      "s2",
		Cwd:            sql.NullString{String: cwd, Valid: true},
		EffectiveState: "idle_done",
		CreatedAt:      nowMinus(30),
	}
	fields := strings.Split(FormatLine(row, "", "dotrc_queue-picker", nowUnix(), false), "\t")
	if got := strings.TrimSpace(fields[colWorktree]); got != "dotrc_queue-picker" {
		t.Errorf("worktree = %q, want dotrc_queue-picker", got)
	}
	// The full cwd still rides along hidden: the attach path opens the window
	// in the directory the session actually ran in.
	if fields[colCwd] != cwd {
		t.Errorf("hidden cwd = %q, want %q", fields[colCwd], cwd)
	}
}

// A resumable row is rendered from the same nine columns as a live one, but
// its state is not one any hook writes, so both icon maps and the summary have
// to know it -- an unmapped state renders as an empty icon and a bare
// "resumable", which is the failure this asserts against.
func TestFormatLine_Resumable(t *testing.T) {
	row := db.Row{
		SessionID:      "s9",
		TmuxPane:       sql.NullString{String: "%3", Valid: true},
		Cwd:            sql.NullString{String: "/home/x/ghq/dotrc_wt", Valid: true},
		TranscriptPath: sql.NullString{String: "/home/x/.claude/projects/enc/s9.jsonl", Valid: true},
		EventType:      "ForcedEnd",
		RawState:       "ended",
		EffectiveState: db.StateResumable,
		PriorState:     sql.NullString{String: "working", Valid: true},
		CreatedAt:      nowMinus(7200),
	}

	fields := strings.Split(FormatLine(row, "", "dotrc_wt", nowUnix(), false), "\t")
	if len(fields) != colCount {
		t.Fatalf("want %d fields, got %d", colCount, len(fields))
	}
	if fields[colIcon] != emoji[db.StateResumable] || fields[colIcon] == "" {
		t.Errorf("emoji icon = %q, want %q", fields[colIcon], emoji[db.StateResumable])
	}
	if !strings.Contains(fields[colSummary], "resumable") {
		t.Errorf("summary = %q, want it to say the row is resumable", fields[colSummary])
	}
	// What the session was doing when it was cut off is the only thing telling
	// these rows apart, so it has to survive into the summary.
	if !strings.Contains(fields[colSummary], "working") {
		t.Errorf("summary = %q, want it to name the prior state", fields[colSummary])
	}
	if fields[colAge] != "2h" {
		t.Errorf("age = %q, want 2h", fields[colAge])
	}
	// The resume path needs both of these off the picked line.
	if fields[colCwd] != "/home/x/ghq/dotrc_wt" || fields[colTranscript] != "/home/x/.claude/projects/enc/s9.jsonl" {
		t.Errorf("hidden cwd/transcript = %q/%q", fields[colCwd], fields[colTranscript])
	}

	asciiIcon := strings.Split(FormatLine(row, "", "dotrc_wt", nowUnix(), true), "\t")[colIcon]
	if asciiIcon == "" {
		t.Error("ascii icon is empty: CLAUDE_QUEUE_ASCII=1 would render the column blank")
	}
	if asciiIcon == fields[colIcon] {
		t.Errorf("ascii icon = %q, same as the emoji one", asciiIcon)
	}
}

// The filesystem half of the resumable test. db.ResumableCandidates cannot make
// it, and skipping it would list rows whose resume silently starts an empty
// session under the same id.
func TestFilterResumable(t *testing.T) {
	row := func(id, cwd, transcript string) db.Row {
		return db.Row{
			SessionID:      id,
			Cwd:            sql.NullString{String: cwd, Valid: cwd != ""},
			TranscriptPath: sql.NullString{String: transcript, Valid: transcript != ""},
			EffectiveState: db.StateResumable,
		}
	}
	// Only these two paths exist.
	files := func(p string) bool { return p == "/t/ok.jsonl" }
	dirs := func(p string) bool { return p == "/w/ok" }

	in := []db.Row{
		row("keep", "/w/ok", "/t/ok.jsonl"),
		row("no-transcript-recorded", "/w/ok", ""),
		row("no-cwd-recorded", "", "/t/ok.jsonl"),
		// A short-lived session records a transcript path but never writes the
		// file, so the ledger having one is only half the check.
		row("transcript-missing", "/w/ok", "/t/gone.jsonl"),
		// A reaped worktree takes the directory the resume would run in.
		row("cwd-reaped", "/w/reaped", "/t/ok.jsonl"),
	}

	got := filterResumable(in, files, dirs)
	if len(got) != 1 || got[0].SessionID != "keep" {
		var ids []string
		for _, r := range got {
			ids = append(ids, r.SessionID)
		}
		t.Fatalf("filterResumable kept %v, want [keep]", ids)
	}

	if got := filterResumable(nil, files, dirs); got != nil {
		t.Errorf("filterResumable(nil) = %+v, want nil", got)
	}
}

// The empty picker is the state a host reboot leaves behind, and the flag that
// would show the recoverable sessions cannot be discovered from inside the
// popup -- so the count has to be in the message.
func TestNoRowsMessage(t *testing.T) {
	const plain = "no active sessions"

	if got := noRowsMessage(0, false); got != plain {
		t.Errorf("nothing to resume = %q, want %q", got, plain)
	}
	// Already listing them: there is nothing left to point at.
	if got := noRowsMessage(3, true); got != plain {
		t.Errorf("with the flag already on = %q, want %q", got, plain)
	}

	got := noRowsMessage(3, false)
	if !strings.Contains(got, "3") {
		t.Errorf("message = %q, want the candidate count in it", got)
	}
	if !strings.Contains(got, "--show-resumable") {
		t.Errorf("message = %q, want it to name the flag", got)
	}
}

// Selecting a resumable row must reach the resume path PR #55 already built,
// not a second one. This walks the whole chain the pick goes through -- render
// the row, split the line, resolve the pane, route -- for a session the roster
// no longer lists.
func TestResumableRowRoutesToResume(t *testing.T) {
	row := db.Row{
		SessionID: testUUID,
		// A pane id left over from a tmux server that has since been replaced.
		// It exists on the current server (it is a per-server counter that
		// restarts from %0), so trusting it would switch to an unrelated pane.
		TmuxPane:       sql.NullString{String: "%1", Valid: true},
		Cwd:            sql.NullString{String: "/w/a", Valid: true},
		TranscriptPath: sql.NullString{String: "/t/a.jsonl", Valid: true},
		EffectiveState: db.StateResumable,
		RawState:       "ended",
		PriorState:     sql.NullString{String: "working", Valid: true},
		CreatedAt:      nowMinus(60),
	}
	sel, ok := parseSelection(FormatLine(row, "", "wt", nowUnix(), false))
	if !ok {
		t.Fatal("parseSelection rejected a line FormatLine rendered")
	}
	mux := &fakeMux{panes: map[string]bool{"%1": true}}

	// The roster was read and does not list the session: the host it ran on went
	// down, so there is no process to displace.
	tgt := Target{
		SessionID:        sel.SessionID,
		Pane:             reachablePane(mux, nil, sel.SessionID, sel.Pane, true),
		Cwd:              sel.Cwd,
		TranscriptPath:   sel.Transcript,
		RosterOK:         true,
		TranscriptExists: true,
		CwdExists:        true,
	}

	act := DecideAction(tgt)
	if act.Kind != "resume" {
		t.Fatalf("Kind = %q, want resume (%+v)", act.Kind, act)
	}
	if act.Resume != testUUID {
		t.Errorf("Resume = %q, want the full uuid %q", act.Resume, testUUID)
	}
	if act.KillPID != 0 {
		t.Errorf("KillPID = %d, want 0: nothing is running to kill", act.KillPID)
	}
	if act.Cwd != "/w/a" {
		t.Errorf("Cwd = %q, want /w/a", act.Cwd)
	}
}

// The unreadable-roster case, which is where a resumable row carrying a pane
// would do real damage. reachablePane's last-resort fallback trusts the ledger
// pane when the roster cannot be read, because an unreadable roster is not
// evidence a session ended -- true for a live row, false for one selected by
// terminated_at. Pane ids are a per-server counter restarting at %0, so after a
// reboot the recorded id resolves to an unrelated live pane and the pick would
// switch to a stranger's session with no error. db.ResumableCandidates withholds
// the column so the fallback has nothing to trust; this asserts the whole chain
// from the rendered line, since it is FormatLine's hidden column that feeds it.
func TestResumableRowCarriesNoPaneForTheRosterFallback(t *testing.T) {
	row := db.Row{
		SessionID:      testUUID,
		TmuxPane:       sql.NullString{}, // what ResumableCandidates hands back
		Cwd:            sql.NullString{String: "/w/a", Valid: true},
		TranscriptPath: sql.NullString{String: "/t/a.jsonl", Valid: true},
		EffectiveState: db.StateResumable,
		RawState:       "ended",
		CreatedAt:      nowMinus(60),
	}
	sel, ok := parseSelection(FormatLine(row, "", "wt", nowUnix(), false))
	if !ok {
		t.Fatal("parseSelection rejected a line FormatLine rendered")
	}
	if sel.Pane != "" {
		t.Fatalf("hidden tmux_pane = %q, want empty for a resumable row", sel.Pane)
	}

	// %0 and %1 exist on the rebooted server, belonging to unrelated sessions.
	mux := &fakeMux{panes: map[string]bool{"%0": true, "%1": true}}
	if got := reachablePane(mux, nil, sel.SessionID, sel.Pane, false); got != "" {
		t.Errorf("reachablePane with an unreadable roster = %q, want empty", got)
	}
}

// A row that came back from the resumable query but whose session turns out to
// be running after all -- reconcile closed it early, or it was restarted since
// -- falls back to the existing routing instead of resuming onto a live
// process. Resumable rows add no branch of their own to DecideAction.
func TestResumableRowInRosterFallsBackToExistingRouting(t *testing.T) {
	agents := []roster.Agent{{SessionID: testUUID, PID: 100, Kind: "background"}}
	mux := &fakeMux{}

	tgt := resumable()
	tgt.Pane = reachablePane(mux, agents, testUUID, "%1", true)
	tgt.InRoster, tgt.Kind, tgt.PID = true, "background", 100

	if act := DecideAction(tgt); act.Kind != "attach" || act.Short != "61c846eb" {
		t.Errorf("DecideAction = %+v, want attach by short id", act)
	}
}

func TestFormatAge(t *testing.T) {
	cases := []struct {
		sec  int64
		want string
	}{
		{30, "30s"},
		{119, "119s"},
		{120, "2m"},
		{60 * 59, "59m"},
		{60 * 60, "1h"},
		{60 * 60 * 24 * 2, "2d"},
	}
	for _, c := range cases {
		if got := formatAge(c.sec); got != c.want {
			t.Errorf("formatAge(%d) = %q, want %q", c.sec, got, c.want)
		}
	}
}

const testUUID = "61c846eb-8205-4a8e-8a0d-7772410051c9"

// resumable is a Target whose resume preconditions all hold, so each case below
// can state only the field it is about.
func resumable() Target {
	return Target{
		SessionID:        testUUID,
		Cwd:              "/w/a",
		TranscriptPath:   "/t/a.jsonl",
		RosterOK:         true,
		TranscriptExists: true,
		CwdExists:        true,
	}
}

// DecideAction is the whole routing rule, and every one of its branches decides
// whether a live process gets a SIGTERM -- so all of them are covered here
// rather than only the interesting ones. The exec calls they route to are
// one-liners in the multiplexer.
func TestDecideAction(t *testing.T) {
	withPane := func(f func(*Target)) Target {
		tgt := resumable()
		f(&tgt)
		return tgt
	}

	cases := []struct {
		name    string
		target  Target
		kind    string
		short   string
		pane    string
		resume  string
		killPID int
	}{{
		// A reachable pane wins over everything else: the session is right there.
		name:   "reachable pane switches",
		target: withPane(func(tg *Target) { tg.Pane = "%12" }),
		kind:   "switch",
		pane:   "%12",
	}, {
		// Even a live interactive session on another server: if its pane came
		// back reachable, nothing may be killed.
		name: "reachable pane beats an orphan process",
		target: withPane(func(tg *Target) {
			tg.Pane, tg.InRoster, tg.Kind, tg.PID, tg.Origin = "%12", true, "interactive", 4242, originOrphan
		}),
		kind: "switch",
		pane: "%12",
	}, {
		name:   "no session id is not actionable",
		target: withPane(func(tg *Target) { tg.SessionID = "" }),
		kind:   "none",
	}, {
		// An unreadable roster is not evidence the process ended, and resuming
		// a live session puts two of them on one transcript.
		name:   "unreadable roster refuses to resume",
		target: withPane(func(tg *Target) { tg.RosterOK = false }),
		kind:   "none",
	}, {
		// `claude attach` only accepts the 8-char short id; the full UUID
		// fails with "No job matching".
		name: "background session attaches by short id",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID = true, "background", 100
		}),
		kind:  "attach",
		short: "61c846eb",
	}, {
		// Short ids that are already <= 8 chars must not be sliced out of range.
		name: "short session id is not truncated",
		target: withPane(func(tg *Target) {
			tg.SessionID, tg.InRoster, tg.Kind, tg.PID = "abc", true, "background", 100
		}),
		kind:  "attach",
		short: "abc",
	}, {
		// `claude agents --json` has been observed to list the same session id
		// under two pids at once -- the duplicate-transcript state a resume
		// must not create. There is no single pid to act on without guessing,
		// so this refuses rather than kill one of the two arbitrarily.
		name: "duplicate roster entries are not touched",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originOrphan
			tg.RosterMatches, tg.DuplicatePIDs = 2, []int{4242, 5252}
		}),
		kind: "none",
	}, {
		// The one case that may kill: the process provably belongs to a tmux
		// server no client of ours can reach.
		name: "orphan interactive session is ended then resumed",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originOrphan
		}),
		kind:    "resume",
		resume:  testUUID,
		killPID: 4242,
	}, {
		name: "session started outside tmux is left alone",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originOutside
		}),
		kind: "none",
	}, {
		// A different tmux server pid is not enough: if that server is
		// confirmed still running, a human may be attached to it from another
		// terminal (a different socket entirely), so it must not be killed.
		name: "interactive session on a still-running foreign server is left alone",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originForeignLive
		}),
		kind: "none",
	}, {
		// /proc unreadable, TMUX unparseable, or no server pid of our own: the
		// safe answer is the same as for a session in use elsewhere.
		name: "unknown origin is left alone",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originUnknown
		}),
		kind: "none",
	}, {
		name: "same-server session with a closed pane is left alone",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originCurrent
		}),
		kind: "none",
	}, {
		name: "orphan with no pid cannot be ended, so is left alone",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 0, originOrphan
		}),
		kind: "none",
	}, {
		// Nothing to displace, so no kill: this is the plain resume.
		name:   "session absent from the roster resumes directly",
		target: resumable(),
		kind:   "resume",
		resume: testUUID,
	}, {
		name:   "no recorded transcript blocks the resume",
		target: withPane(func(tg *Target) { tg.TranscriptPath, tg.TranscriptExists = "", false }),
		kind:   "none",
	}, {
		// Short-lived sessions never write a jsonl, so a recorded path is only
		// half the check. `claude --resume` with an id it cannot find starts an
		// empty session under that id instead of failing.
		name:   "transcript missing on disk blocks the resume",
		target: withPane(func(tg *Target) { tg.TranscriptExists = false }),
		kind:   "none",
	}, {
		name:   "no recorded cwd blocks the resume",
		target: withPane(func(tg *Target) { tg.Cwd, tg.CwdExists = "", false }),
		kind:   "none",
	}, {
		// A reaped worktree takes the cwd resume resolves transcripts against.
		name:   "reaped cwd blocks the resume",
		target: withPane(func(tg *Target) { tg.CwdExists = false }),
		kind:   "none",
	}, {
		// The preconditions gate the kill path too: an orphan whose transcript
		// is gone must not be killed for a resume that cannot happen.
		name: "orphan with no transcript is not killed",
		target: withPane(func(tg *Target) {
			tg.InRoster, tg.Kind, tg.PID, tg.Origin = true, "interactive", 4242, originOrphan
			tg.TranscriptExists = false
		}),
		kind: "none",
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := DecideAction(c.target)
			if got.Kind != c.kind {
				t.Fatalf("Kind = %q, want %q (%+v)", got.Kind, c.kind, got)
			}
			if got.Pane != c.pane {
				t.Errorf("Pane = %q, want %q", got.Pane, c.pane)
			}
			if got.Short != c.short {
				t.Errorf("Short = %q, want %q", got.Short, c.short)
			}
			if got.Resume != c.resume {
				t.Errorf("Resume = %q, want %q", got.Resume, c.resume)
			}
			if got.KillPID != c.killPID {
				t.Errorf("KillPID = %d, want %d", got.KillPID, c.killPID)
			}
			if c.kind == "none" && got.Reason == "" {
				t.Error("none without a reason: the pick would look like a no-op")
			}
			if c.kind == "attach" || c.kind == "resume" {
				if got.Cwd != c.target.Cwd {
					t.Errorf("Cwd = %q, want %q", got.Cwd, c.target.Cwd)
				}
			}
		})
	}
}

// A row whose tmux_pane went NULL still has a live process, and when that
// process runs in the current tmux server the picker must switch to its pane
// rather than fall through to `claude attach` -- which only serves background
// jobs and would silently close a fresh window for an interactive session.
func TestPaneForSession(t *testing.T) {
	agents := []roster.Agent{
		{SessionID: "bg", PID: 100, Kind: "background"},
		{SessionID: "live", PID: 200, Kind: "interactive"},
	}
	// Only pid 200 sits under a pane; 100 is a background agent with none.
	find := func(pid int) (string, bool) {
		if pid == 200 {
			return "%7", true
		}
		return "", false
	}

	if got := paneForSession(agents, "live", find); got != "%7" {
		t.Errorf("paneForSession(live) = %q, want %%7", got)
	}
	// A live agent with no pane must stay empty so DecideAction routes it to
	// attach, which is the correct path for a background session.
	if got := paneForSession(agents, "bg", find); got != "" {
		t.Errorf("paneForSession(bg) = %q, want empty", got)
	}
	// A session the roster does not list is already gone; nothing to resolve.
	if got := paneForSession(agents, "missing", find); got != "" {
		t.Errorf("paneForSession(missing) = %q, want empty", got)
	}
	if got := paneForSession(nil, "live", find); got != "" {
		t.Errorf("paneForSession over an empty roster = %q, want empty", got)
	}
}

// fakeMux is a Multiplexer whose pane answers are set per test. Only the
// lookups reachablePane makes are wired; Switch and OpenSession are the exec
// one-liners this package does not test.
type fakeMux struct {
	panes     map[string]bool // PaneExists
	find      map[int]string  // FindPane
	serverPID int             // ServerPID; 0 means "no server"
}

func (f *fakeMux) PaneID() string                                         { return "" }
func (f *fakeMux) RefreshStatus()                                         {}
func (f *fakeMux) Switch(target string) error                             { return nil }
func (f *fakeMux) OpenSession(name, cwd, window string, a []string) error { return nil }

// The window-naming methods are equally unused here: picker.Run drives them,
// and Run is the exec boundary these tests stay on the near side of.
func (f *fakeMux) RenameWindow(pane, name string) error          { return nil }
func (f *fakeMux) SetAutomaticRename(pane string, on bool) error { return nil }
func (f *fakeMux) WindowName(pane string) (string, bool)         { return "", false }
func (f *fakeMux) WindowPaneCount(pane string) (int, bool)       { return 0, false }
func (f *fakeMux) FindPane(pid int) (string, bool) {
	pane, ok := f.find[pid]
	return pane, ok
}
func (f *fakeMux) PaneExists(target string) bool { return f.panes[target] }
func (f *fakeMux) ServerPID() (int, bool)        { return f.serverPID, f.serverPID > 0 }

// The ledger's pane column is not identity-checked: PaneExists only proves
// *some* pane on this server has that id, not that it belongs to the picked
// session. tmux pane ids are a per-server counter that restarts from %0 on a
// fresh server, so a stale id from a since-replaced server can collide with
// an unrelated live pane. Whenever the roster can name the session's actual
// process, its pane is re-derived by walking that process's ancestry instead
// -- an identity check PaneExists cannot offer -- and the ledger column is
// used as-is only when the roster itself could not be read (rosterOK is
// false), never when it was read successfully but simply lists no entry for
// the session: that absence is evidence the process ended, not a reason to
// trust a stale id.
func TestReachablePane(t *testing.T) {
	live := []roster.Agent{{SessionID: "live", PID: 200, Kind: "interactive"}}
	dup := []roster.Agent{
		{SessionID: "dup", PID: 200, Kind: "interactive"},
		{SessionID: "dup", PID: 201, Kind: "interactive"},
	}

	cases := []struct {
		name       string
		agents     []roster.Agent
		mux        *fakeMux
		sessionID  string
		ledgerPane string
		rosterOK   bool
		want       string
	}{{
		// Gate (a): once the roster names the session's process, its
		// identity-verified pane wins even over a ledger pane that also
		// exists on this server -- the ledger id may be an unrelated pane
		// that happens to collide.
		name:       "roster-verified pane wins over a live ledger pane",
		agents:     live,
		mux:        &fakeMux{panes: map[string]bool{"%3": true}, find: map[int]string{200: "%7"}},
		sessionID:  "live",
		ledgerPane: "%3",
		rosterOK:   true,
		want:       "%7",
	}, {
		name:       "stale ledger pane falls back to re-resolution",
		agents:     live,
		mux:        &fakeMux{find: map[int]string{200: "%7"}},
		sessionID:  "live",
		ledgerPane: "%3",
		rosterOK:   true,
		want:       "%7",
	}, {
		// The roster names the process but its ancestry resolves to no pane
		// at all (e.g. it lives on another server). Even though the ledger id
		// happens to exist on this server, it must not be trusted: the roster
		// already had identity to check and it did not confirm this pane.
		name:       "ledger pane collision with an unrelated live pane is not trusted",
		agents:     live,
		mux:        &fakeMux{panes: map[string]bool{"%3": true}},
		sessionID:  "live",
		ledgerPane: "%3",
		rosterOK:   true,
		want:       "",
	}, {
		name:      "empty ledger pane re-resolves",
		agents:    live,
		mux:       &fakeMux{find: map[int]string{200: "%7"}},
		sessionID: "live",
		rosterOK:  true,
		want:      "%7",
	}, {
		// Gate (b): the ledger pane is the fallback of last resort, used only
		// when the roster itself could not be read -- there is nothing better
		// to check identity against.
		name:       "roster unreadable falls back to the ledger pane",
		agents:     live,
		mux:        &fakeMux{panes: map[string]bool{"%9": true}},
		sessionID:  "gone",
		ledgerPane: "%9",
		rosterOK:   false,
		want:       "%9",
	}, {
		// The roster was read successfully and simply has no entry for this
		// session: that is evidence the process ended, not a reason to trust
		// a ledger pane that may belong to a since-replaced server. "" here
		// is what routes DecideAction to the resume path instead of a
		// possibly-unrelated live pane.
		name:       "roster read but session absent does not use the ledger pane",
		agents:     live,
		mux:        &fakeMux{panes: map[string]bool{"%9": true}},
		sessionID:  "gone",
		ledgerPane: "%9",
		rosterOK:   true,
		want:       "",
	}, {
		name:       "session absent from roster and ledger pane not on this server",
		agents:     live,
		mux:        &fakeMux{},
		sessionID:  "gone",
		ledgerPane: "%9",
		rosterOK:   false,
		want:       "",
	}, {
		// A roster entry duplicated under two pids (see Target.RosterMatches)
		// must not stop pane resolution at the first pid tried.
		name:      "duplicate roster entries try every pid for a pane",
		agents:    dup,
		mux:       &fakeMux{find: map[int]string{201: "%8"}},
		sessionID: "dup",
		rosterOK:  true,
		want:      "%8",
	}, {
		// Nothing to look the process up by, and an empty pane column: the row
		// is not reachable by any pane.
		name:       "no session id and no ledger pane",
		agents:     live,
		mux:        &fakeMux{find: map[int]string{200: "%7"}},
		ledgerPane: "",
		rosterOK:   true,
		want:       "",
	}}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := reachablePane(c.mux, c.agents, c.sessionID, c.ledgerPane, c.rosterOK); got != c.want {
				t.Errorf("reachablePane = %q, want %q", got, c.want)
			}
		})
	}
}

// The re-derived pane has to reach DecideAction as if it had come from the
// ledger, so the pick lands on the switch path rather than on a resume that
// would kill a session whose pane is right here.
func TestReachablePaneRoutesToSwitch(t *testing.T) {
	agents := []roster.Agent{{SessionID: testUUID, PID: 200, Kind: "interactive"}}
	mux := &fakeMux{find: map[int]string{200: "%7"}}

	tgt := resumable()
	tgt.InRoster, tgt.Kind, tgt.PID, tgt.Origin = true, "interactive", 200, originOrphan
	tgt.Pane = reachablePane(mux, agents, testUUID, "%stale", true)

	if act := DecideAction(tgt); act.Kind != "switch" || act.Pane != "%7" {
		t.Errorf("DecideAction with a re-derived pane = %+v, want switch to %%7", act)
	}
}

// The wait after a SIGTERM is what keeps a resume from opening a transcript the
// dying process is still flushing. It has to be sure the session ended, so an
// unreadable roster counts as "still there" rather than as "gone".
func TestWaitGone(t *testing.T) {
	present := []roster.Agent{{SessionID: "s", PID: 1}}
	rosterErr := errors.New("claude agents --json: exit 1")

	t.Run("absent immediately", func(t *testing.T) {
		ticks := 0
		ok := waitGone("s", func() ([]roster.Agent, error) { return nil, nil }, func() { ticks++ }, 5)
		if !ok || ticks != 1 {
			t.Errorf("got (%v, %d ticks), want (true, 1 tick)", ok, ticks)
		}
	})

	t.Run("leaves partway through", func(t *testing.T) {
		reads := 0
		list := func() ([]roster.Agent, error) {
			reads++
			if reads < 3 {
				return present, nil
			}
			return nil, nil
		}
		if !waitGone("s", list, func() {}, 5) {
			t.Error("waitGone = false, want true once the session leaves the roster")
		}
	})

	t.Run("never leaves", func(t *testing.T) {
		ticks := 0
		ok := waitGone("s", func() ([]roster.Agent, error) { return present, nil }, func() { ticks++ }, 4)
		if ok || ticks != 4 {
			t.Errorf("got (%v, %d ticks), want (false, 4 ticks)", ok, ticks)
		}
	})

	t.Run("unreadable roster is not proof of death", func(t *testing.T) {
		if waitGone("s", func() ([]roster.Agent, error) { return nil, rosterErr }, func() {}, 3) {
			t.Error("waitGone = true on an unreadable roster, want false")
		}
	})

	// Another session leaving does not stand in for this one.
	t.Run("other sessions do not count", func(t *testing.T) {
		other := []roster.Agent{{SessionID: "t", PID: 2}}
		if !waitGone("s", func() ([]roster.Agent, error) { return other, nil }, func() {}, 2) {
			t.Error("waitGone = false when only another session is listed, want true")
		}
	})
}

func TestWindowNameFor(t *testing.T) {
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	line := `{"type":"ai-title","aiTitle":"GitHub App PR 作成","sessionId":"6773febd"}` + "\n"
	if err := os.WriteFile(path, []byte(line), 0600); err != nil {
		t.Fatalf("write transcript: %v", err)
	}
	const sessionID = "6773febd-ce31-4e22-8354-5bc0d72c18a1"

	t.Run("named after the conversation", func(t *testing.T) {
		if got, want := windowNameFor(path, sessionID, "attach"), "GitHub-App-PR-作-6773febd"; got != want {
			t.Errorf("windowNameFor = %q, want %q", got, want)
		}
	})

	// The fallback keeps the one virtue the old argv-derived name had: it is
	// unique per session, so new-window -S still collapses repeat picks of the
	// same row onto one window.
	t.Run("falls back per action kind", func(t *testing.T) {
		missing := filepath.Join(t.TempDir(), "absent.jsonl")
		if got, want := windowNameFor(missing, sessionID, "attach"), "attach-6773febd"; got != want {
			t.Errorf("windowNameFor = %q, want %q", got, want)
		}
		if got, want := windowNameFor(missing, sessionID, "resume"), "resume-6773febd"; got != want {
			t.Errorf("windowNameFor = %q, want %q", got, want)
		}
	})
}
