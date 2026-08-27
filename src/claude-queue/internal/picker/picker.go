package picker

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/multiplexer"
	"github.com/knagiri/dotrc/src/claude-queue/internal/reconcile"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
	"github.com/knagiri/dotrc/src/claude-queue/internal/summary"
)

var emoji = map[string]string{
	"awaiting_approval": "⏳",
	"idle_done":         "✅",
	"working":           "⚙️",
	"stale":             "🧟",
	db.StateResumable:   "💤",
}

var ascii = map[string]string{
	"awaiting_approval": "[!]",
	"idle_done":         "[.]",
	"working":           "[*]",
	"stale":             "[X]",
	db.StateResumable:   "[~]",
}

// FormatLine renders one queue row as a tab-delimited line for fzf.
// Visible columns (--with-nth=1,2,3,4): icon, worktree, summary, age.
// The worktree name comes right after the icon so it starts at a fixed
// position and stays scannable; the variable-width summary is demoted behind
// it and left untruncated.
// Hidden columns: session_id (5), tmux_pane (6), full cwd (7),
// transcript_path (8). The full cwd is carried separately from the worktree
// name because a background session is opened in a window that needs a real
// working directory; the transcript path rides along because the resume path
// must not run without confirming the conversation file is actually on disk.
//
// worktree is passed in rather than derived here: resolving it needs git (see
// worktreeName), and keeping FormatLine pure is what lets the column contract
// be asserted without a repository on disk.
func FormatLine(row db.Row, worktree string, nowSec int64, asciiMode bool) string {
	icons := emoji
	if asciiMode {
		icons = ascii
	}
	icon := icons[row.EffectiveState]

	sum := summary.Summarize(summary.Input{
		EffectiveState: row.EffectiveState,
		RawState:       row.RawState,
		Payload:        row.Payload.String,
		PriorState:     row.PriorState.String,
	})

	age := formatAge(nowSec - row.CreatedAt)

	pane := ""
	if row.TmuxPane.Valid {
		pane = row.TmuxPane.String
	}

	return strings.Join([]string{
		icon, worktree, sum, age,
		row.SessionID, pane, rowCwd(row), rowTranscript(row),
	}, "\t")
}

// rowCwd unwraps the nullable cwd column into the "" that the rest of the
// picker treats as "no working directory recorded".
func rowCwd(row db.Row) string {
	if row.Cwd.Valid {
		return row.Cwd.String
	}
	return ""
}

// rowTranscript unwraps transcript_path the same way; "" means the ledger never
// recorded one, which the resume path treats as "nothing to resume".
func rowTranscript(row db.Row) string {
	if row.TranscriptPath.Valid {
		return row.TranscriptPath.String
	}
	return ""
}

// filterResumable drops the candidates whose resume would fail, which is the
// half of the test db.ResumableCandidates cannot make: both preconditions live
// on disk rather than in the ledger.
//
// It is the same pair resumeBlocked checks when a row is picked, applied a step
// earlier so a candidate that cannot be reopened is never listed at all -- and
// so the count reported when the queue is empty is a count of rows that will
// actually resume. fileExists and dirExists are parameters so the rule can be
// exercised without laying out transcripts and worktrees on a real filesystem.
func filterResumable(rows []db.Row, fileExists, dirExists func(string) bool) []db.Row {
	var out []db.Row
	for _, r := range rows {
		transcript, cwd := rowTranscript(r), rowCwd(r)
		if transcript == "" || cwd == "" {
			continue
		}
		if !fileExists(transcript) || !dirExists(cwd) {
			continue
		}
		out = append(out, r)
	}
	return out
}

// noRowsMessage explains an empty picker. The resumable count is the reason it
// is not just a constant: a host that has just come back up has no live session
// at all, and that is precisely when the flag that would show the recoverable
// ones needs advertising -- there is no way to discover it from inside the
// popup.
func noRowsMessage(resumable int, shown bool) string {
	if resumable == 0 || shown {
		return "no active sessions"
	}
	return fmt.Sprintf(
		"no active sessions, but %d can be resumed: reopen the picker with --show-resumable (prefix Q)",
		resumable)
}

func formatAge(sec int64) string {
	switch {
	case sec < 0:
		return "0s"
	case sec < 120:
		return fmt.Sprintf("%ds", sec)
	case sec < 3600:
		return fmt.Sprintf("%dm", sec/60)
	case sec < 86400:
		return fmt.Sprintf("%dh", sec/3600)
	default:
		return fmt.Sprintf("%dd", sec/86400)
	}
}

// Target is everything DecideAction needs to know about a picked row: what the
// ledger recorded, what the live roster says about the session's process, and
// whether the two files a resume depends on are actually there.
//
// Gathering it costs subprocesses and stat calls, all of which stay in Run;
// this struct is the seam that keeps the routing rule -- the part with branches
// worth testing -- free of them.
type Target struct {
	SessionID      string // full UUID as the ledger holds it
	Pane           string // pane confirmed reachable on this server, or ""
	Cwd            string
	TranscriptPath string

	// RosterOK distinguishes "the roster says this session is not running"
	// from "the roster could not be read", which is the same distinction
	// reconcile.Sweep turns on. Only the former is evidence the process ended,
	// and resuming a session whose process is still alive puts two of them on
	// one transcript.
	RosterOK bool
	InRoster bool
	Kind     string // roster kind: "interactive" | "background"
	PID      int
	Origin   serverOrigin

	// RosterMatches is how many roster entries carry SessionID. `claude agents
	// --json` has been observed to list the same session id under two pids
	// (a resume that raced a still-running process onto the same transcript,
	// which is exactly the state this package must not create). >1 means
	// identity is ambiguous: acting on "the" pid would pick one of the two
	// arbitrarily, so DecideAction refuses instead of guessing.
	RosterMatches int
	// DuplicatePIDs holds every pid RosterMatches counted, for the "none"
	// message when RosterMatches > 1.
	DuplicatePIDs []int

	TranscriptExists bool
	CwdExists        bool
}

// Action is what selecting a picker row should do.
type Action struct {
	Kind    string // "switch" | "attach" | "resume" | "none"
	Pane    string // switch: tmux pane id
	Short   string // attach: 8-char session id, the only form `claude attach` takes
	Cwd     string // attach / resume: working directory for the new window
	Resume  string // resume: full UUID, the form `claude --resume` needs
	KillPID int    // resume: pid to SIGTERM first; 0 when no process is left
	Reason  string // none: message for stderr
}

// DecideAction routes a selected row, in the order the four reachable states
// were measured in:
//
//  1. A pane we can reach is always the answer -- the session is right there.
//  2. A background session has no pane (it does not inherit $TMUX_PANE), so it
//     is opened with `claude attach` in a fresh window. This is also the only
//     way a background session blocked on a permission prompt gets answered.
//  3. An interactive session with no reachable pane cannot be attached at all:
//     `claude attach` serves background jobs only and answers "No job matching
//     <id>", and because `tmux new-window` reports the status of creating the
//     window rather than of the command inside it, the window opens, the
//     command fails, the window closes, and the pick looks like a no-op. The
//     conversation is recoverable by resuming its transcript instead -- but
//     `claude --resume` does not take over the running process, it starts a
//     second one on the same transcript. So the process has to end first, and
//     that is only safe when its tmux server is provably not ours: anything
//     else may be a session a human is using in another terminal.
//  4. A session the roster does not list has no process to displace, so it
//     resumes directly.
//
// Resuming needs the transcript and the working directory to exist, which is
// checked last so it covers both paths that reach it. `claude --resume` with an
// id it cannot find does not fail -- it silently starts an empty session under
// that id -- so an unverified resume would look like success and lose the row.
func DecideAction(t Target) Action {
	if t.Pane != "" {
		return Action{Kind: "switch", Pane: t.Pane}
	}
	if t.SessionID == "" {
		return Action{Kind: "none", Reason: "no tmux pane and no session id recorded"}
	}
	if !t.RosterOK {
		return Action{Kind: "none", Reason: "live agent roster unreadable, so the session may still be running: not resuming"}
	}
	if t.RosterMatches > 1 {
		// The roster already has two processes on this session id -- the
		// duplicate-transcript state a resume must not create. There is no
		// single pid a kill or an attach can target without guessing which
		// entry is the "real" one, so the conservative answer is to leave
		// both alone and report what was seen.
		return Action{Kind: "none", Reason: fmt.Sprintf(
			"session %s appears %d times in the live roster (pids %v): not touching it",
			shortID(t.SessionID), t.RosterMatches, t.DuplicatePIDs)}
	}
	if t.InRoster {
		if t.Kind == "background" {
			return Action{Kind: "attach", Short: shortID(t.SessionID), Cwd: t.Cwd}
		}
		if t.Origin != originOrphan {
			return Action{Kind: "none", Reason: fmt.Sprintf(
				"session %s is running (pid %d, %s) and may be in use in another terminal: not resuming",
				shortID(t.SessionID), t.PID, t.Origin)}
		}
		if t.PID <= 0 {
			return Action{Kind: "none", Reason: "session runs on another tmux server but the roster recorded no pid to end it with"}
		}
	}
	if reason := resumeBlocked(t); reason != "" {
		return Action{Kind: "none", Reason: reason}
	}
	act := Action{Kind: "resume", Resume: t.SessionID, Cwd: t.Cwd}
	if t.InRoster {
		act.KillPID = t.PID
	}
	return act
}

// resumeBlocked names the missing precondition for a resume, or "" when there
// is none. Both are on disk rather than in the ledger, so the ledger having
// recorded a path is only half the check.
func resumeBlocked(t Target) string {
	switch {
	case t.TranscriptPath == "":
		return "cannot resume: the ledger recorded no transcript path for this session"
	case !t.TranscriptExists:
		return "cannot resume: transcript " + t.TranscriptPath + " is not on disk (the session ended before writing one)"
	case t.Cwd == "":
		return "cannot resume: the ledger recorded no working directory for this session"
	case !t.CwdExists:
		return "cannot resume: working directory " + t.Cwd + " no longer exists (its worktree was reaped)"
	}
	return ""
}

// shortID truncates a session id to the 8 chars `claude attach` takes, and the
// form every message about a session uses.
func shortID(sessionID string) string {
	if len(sessionID) > 8 {
		return sessionID[:8]
	}
	return sessionID
}

// reachablePane returns a pane of the current server the picked row can be
// switched to. "" means none is reachable.
//
// The ledger's pane column is never trusted on its own. `PaneExists` is only a
// membership test against the current server's pane table -- it does not
// confirm the pane belongs to *this* session -- and tmux pane ids are a
// per-server counter that a fresh server restarts from %0. A stale id
// recorded under a since-replaced server therefore collides with an unrelated
// live pane on the current one almost certainly, and PaneExists reports that
// collision as true. So whenever the roster can identify the session's actual
// process, its pane is re-derived by walking that process's ancestry
// (paneForSession) instead -- an identity check the ledger id cannot offer.
//
// The ledger pane is used as-is only when the roster could not be consulted
// at all (rosterOK is false): there is nothing better to fall back to, and an
// unreadable roster is not evidence the session ended. It is deliberately
// NOT used when the roster was read successfully but simply has no entry for
// sessionID -- that absence is itself evidence the process ended (the same
// signal reconcile.Sweep acts on), so a ledger pane surviving under a
// since-replaced server is never that session's pane and trusting it would
// switch to an unrelated live pane that happens to share the stale id.
// Returning "" here instead routes DecideAction to the resume path, which is
// the correct outcome for a session the roster no longer lists.
func reachablePane(mux multiplexer.Multiplexer, agents []roster.Agent, sessionID, ledgerPane string, rosterOK bool) string {
	if len(agentsFor(agents, sessionID)) > 0 {
		return paneForSession(agents, sessionID, mux.FindPane)
	}
	if !rosterOK && ledgerPane != "" && mux.PaneExists(ledgerPane) {
		return ledgerPane
	}
	return ""
}

// paneForSession is the process-tree lookup itself, taking the pane finder as an
// argument so the roster-to-pane wiring can be tested without tmux.
//
// It tries every roster entry for sessionID, not just the first: `claude
// agents --json` has been observed to list the same session id twice (see
// Target.RosterMatches), and stopping at the first entry risks missing the
// one pid that actually resolves to a pane.
func paneForSession(agents []roster.Agent, sessionID string, find func(int) (string, bool)) string {
	for _, a := range agentsFor(agents, sessionID) {
		if pane, found := find(a.PID); found {
			return pane
		}
	}
	// The session is live but outside this tmux server (a session that
	// outlived the server it started in, or a background agent that never had
	// a pane). Which of the two it is decides whether the session may be
	// killed and resumed, and that is originOf's question, not this one's.
	return ""
}

// agentsFor returns every roster entry for sessionID. Session ids are not
// guaranteed unique there -- see Target.RosterMatches -- so callers that act
// on identity (pane resolution, kill, resume) need to see all of them rather
// than assume the first is the only one.
func agentsFor(agents []roster.Agent, sessionID string) []roster.Agent {
	if sessionID == "" {
		return nil
	}
	var matches []roster.Agent
	for _, a := range agents {
		if a.SessionID == sessionID {
			matches = append(matches, a)
		}
	}
	return matches
}

// killPollAttempts and killPollInterval bound the wait for a SIGTERM'd session
// to leave the roster: 10s in half-second steps. Claude flushes its transcript
// on the way out, so resuming before it is gone would reopen a half-written
// conversation -- and would also be the two-processes-one-transcript state the
// kill exists to avoid.
const (
	killPollAttempts = 20
	killPollInterval = 500 * time.Millisecond
)

// endSession asks pid to exit and waits for the roster to stop listing
// sessionID.
//
// SIGTERM only, never SIGKILL: a session that ignores the signal is a session
// still holding its transcript, and forcing it out risks losing the very
// conversation the resume is trying to recover. Refusing to resume is the
// conservative answer -- the user keeps a live process and an intact transcript
// and can decide what to do with them.
func endSession(pid int, sessionID string) error {
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		return fmt.Errorf("SIGTERM to pid %d: %w", pid, err)
	}
	if !waitGone(sessionID, roster.List, func() { time.Sleep(killPollInterval) }, killPollAttempts) {
		return fmt.Errorf("session %s is still in the roster after SIGTERM to pid %d", shortID(sessionID), pid)
	}
	return nil
}

// waitGone polls until the roster stops listing sessionID, with the roster read
// and the sleep injected so the loop is testable without a process to kill.
//
// A roster that cannot be read counts as "still there": it is not evidence the
// session ended, and the whole point of the wait is to be sure it did.
func waitGone(sessionID string, list func() ([]roster.Agent, error), tick func(), attempts int) bool {
	for i := 0; i < attempts; i++ {
		tick()
		agents, err := list()
		if err != nil {
			continue
		}
		if len(agentsFor(agents, sessionID)) == 0 {
			return true
		}
	}
	return false
}

// Run is the CLI entrypoint for `claude-queue picker`.
func Run(args []string) {
	fs := flag.NewFlagSet("picker", flag.ExitOnError)
	showWorking := fs.Bool("show-working", false, "include working sessions")
	showStale := fs.Bool("show-stale", false, "include stale sessions")
	showResumable := fs.Bool("show-resumable", false, "include ended sessions a resume could reopen")
	_ = fs.Parse(args)

	conn, err := db.Open(db.DefaultPath())
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return
	}
	defer conn.Close()

	// Reconcile before reading the rows, so the list never offers a session
	// that has already vanished. This is the cheapest place to put it: the
	// picker is user-driven (so it runs rarely) and it is the one caller that
	// would otherwise show the stale rows. Best-effort -- an unreadable roster
	// is no reason to refuse to display the queue.
	if n, err := reconcile.Sweep(conn); err != nil {
		fmt.Fprintln(os.Stderr, "reconcile skipped:", err)
	} else if n > 0 {
		fmt.Fprintf(os.Stderr, "reconciled %d ended session(s)\n", n)
	}

	rows, err := db.ListRows(conn, db.ListOpts{
		ShowWorking: *showWorking,
		ShowStale:   *showStale,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return
	}
	// Read the resumable rows whether or not they will be listed: the count is
	// what the empty-queue message needs in order to point at the flag.
	// Best-effort for the same reason the sweep above is -- a failure here is no
	// reason to withhold the live queue.
	var resumable []db.Row
	if cands, err := db.ResumableCandidates(conn); err != nil {
		fmt.Fprintln(os.Stderr, "resumable lookup skipped:", err)
	} else {
		resumable = filterResumable(cands, isFile, isDir)
	}
	if *showResumable {
		// Appended, not merged: ResumableCandidates hands back priorities above
		// every one the queue view assigns, so concatenation is already the
		// global order and fzf is run with --no-sort.
		rows = append(rows, resumable...)
	}

	if len(rows) == 0 {
		fmt.Fprintln(os.Stderr, noRowsMessage(len(resumable), *showResumable))
		return
	}

	var buf bytes.Buffer
	now := time.Now().Unix()
	asciiMode := os.Getenv("CLAUDE_QUEUE_ASCII") == "1"
	names := worktreeCache{}
	for _, r := range rows {
		buf.WriteString(FormatLine(r, names.name(rowCwd(r)), now, asciiMode))
		buf.WriteByte('\n')
	}

	selected, err := runFzf(buf.String())
	if err != nil || selected == "" {
		return
	}

	fields := strings.Split(selected, "\t")
	if len(fields) < 8 {
		return
	}
	sessionID := strings.TrimSpace(fields[4])
	ledgerPane := strings.TrimSpace(fields[5])
	cwd := strings.TrimSpace(fields[6])
	transcript := strings.TrimSpace(fields[7])

	mux := multiplexer.Detect()

	switch act := DecideAction(describeTarget(mux, sessionID, ledgerPane, cwd, transcript)); act.Kind {
	case "switch":
		// A failed switch does not terminate the row. Every pane that reaches
		// here was confirmed present in this server's pane table moments ago
		// (see reachablePane), so a failure is about the switch itself -- no
		// client attached, a pane closed in between -- and not evidence that
		// the session died. Closing rows is reconcile.Sweep's job, and it
		// decides from the authoritative roster instead of from a guess.
		if err := mux.Switch(act.Pane); err != nil {
			fmt.Fprintf(os.Stderr, "switch to %s failed: %v\n", act.Pane, err)
		}
	case "attach":
		// Open the session belonging to the row's worktree, not whichever
		// session the popup happened to be invoked from -- that is what keeps
		// "1 worktree = 1 tmux session" (the gts / claude-worktree convention)
		// intact. The cache lookup is a hit: the name was already resolved to
		// render this row.
		//
		// Do NOT terminate the session on failure the way the pane path does:
		// a failed window open says nothing about whether the session is alive,
		// and the manual command still works.
		if err := mux.OpenSession(names.name(act.Cwd), act.Cwd, []string{"claude", "attach", act.Short}); err != nil {
			fmt.Fprintf(os.Stderr, "open session failed: %v\nrun: claude attach %s\n", err, act.Short)
		}
	case "resume":
		// Reopen the conversation from its transcript. `claude --resume` keeps
		// the session id, so the ledger row survives the restart rather than
		// being replaced by a second one. The full UUID is required: the short
		// form is what `claude attach` takes, not this.
		if act.KillPID != 0 {
			if err := endSession(act.KillPID, act.Resume); err != nil {
				fmt.Fprintf(os.Stderr, "not resuming: %v\n", err)
				return
			}
		}
		if err := mux.OpenSession(names.name(act.Cwd), act.Cwd, []string{"claude", "--resume", act.Resume}); err != nil {
			fmt.Fprintf(os.Stderr, "open session failed: %v\nrun: cd %s && claude --resume %s\n", err, act.Cwd, act.Resume)
		}
	default:
		fmt.Fprintln(os.Stderr, act.Reason)
	}
}

// describeTarget gathers the state DecideAction routes on: the reachable pane,
// the live roster's view of the session, and whether the resume preconditions
// hold on disk.
//
// The roster is read once here for both the pane lookup and the routing, since
// each read costs a subprocess. It is read for the single picked row only: the
// panes of rows the user did not select are never needed.
func describeTarget(mux multiplexer.Multiplexer, sessionID, ledgerPane, cwd, transcript string) Target {
	agents, err := roster.List()
	if err != nil {
		fmt.Fprintln(os.Stderr, "roster lookup skipped:", err)
	}
	pane := reachablePane(mux, agents, sessionID, ledgerPane, err == nil)

	t := Target{
		SessionID:      sessionID,
		Pane:           pane,
		Cwd:            cwd,
		TranscriptPath: transcript,
		RosterOK:       err == nil,

		TranscriptExists: isFile(transcript),
		CwdExists:        isDir(cwd),
	}
	matches := agentsFor(agents, sessionID)
	t.RosterMatches = len(matches)
	if t.RosterMatches > 1 {
		for _, a := range matches {
			t.DuplicatePIDs = append(t.DuplicatePIDs, a.PID)
		}
	}
	if len(matches) > 0 {
		a := matches[0]
		t.InRoster, t.Kind, t.PID = true, a.Kind, a.PID
		if pane == "" {
			// Only asked when the pane is unreachable: that is the one case
			// where the process's tmux server changes what we may do to it.
			serverPID, _ := mux.ServerPID()
			t.Origin = originOf(a.PID, serverPID)
		}
	}
	return t
}

func isFile(path string) bool {
	if path == "" {
		return false
	}
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}

func isDir(path string) bool {
	if path == "" {
		return false
	}
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

func runFzf(input string) (string, error) {
	cmd := exec.Command("fzf",
		"--delimiter=\t",
		"--with-nth=1,2,3,4",
		"--no-sort",
		"--reverse",
		"--height=100%",
	)
	cmd.Stdin = strings.NewReader(input)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimRight(string(out), "\n"), nil
}
