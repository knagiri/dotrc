package picker

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
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
}

var ascii = map[string]string{
	"awaiting_approval": "[!]",
	"idle_done":         "[.]",
	"working":           "[*]",
	"stale":             "[X]",
}

// FormatLine renders one queue row as a tab-delimited line for fzf.
// Visible columns (--with-nth=1,2,3,4): icon, worktree, summary, age.
// The worktree name comes right after the icon so it starts at a fixed
// position and stays scannable; the variable-width summary is demoted behind
// it and left untruncated.
// Hidden columns: session_id (5), tmux_pane (6), full cwd (7). The full cwd is
// carried separately from the worktree name because a background session is
// opened in a window that needs a real working directory.
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
	})

	age := formatAge(nowSec - row.CreatedAt)

	pane := ""
	if row.TmuxPane.Valid {
		pane = row.TmuxPane.String
	}

	return strings.Join([]string{icon, worktree, sum, age, row.SessionID, pane, rowCwd(row)}, "\t")
}

// rowCwd unwraps the nullable cwd column into the "" that the rest of the
// picker treats as "no working directory recorded".
func rowCwd(row db.Row) string {
	if row.Cwd.Valid {
		return row.Cwd.String
	}
	return ""
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

// Action is what selecting a picker row should do. Keeping the decision in a
// pure function separates the routing rule -- which is the part with branches
// worth testing -- from the exec calls that carry it out.
type Action struct {
	Kind   string // "switch" | "attach" | "none"
	Pane   string // switch: tmux pane id
	Short  string // attach: 8-char session id, the only form `claude attach` takes
	Cwd    string // attach: working directory for the new window
	Reason string // none: message for stderr
}

// DecideAction routes a selected row. A session tracked with a tmux pane is
// reached by switching to it. A background session has no pane (it does not
// inherit $TMUX_PANE), so it is opened with `claude attach` in a fresh window
// instead -- which is also how a background session blocked on a permission
// prompt gets answered, since that prompt cannot be routed anywhere else.
func DecideAction(sessionID, pane, cwd string) Action {
	if pane != "" {
		return Action{Kind: "switch", Pane: pane}
	}
	if sessionID == "" {
		return Action{Kind: "none", Reason: "no tmux pane and no session id recorded"}
	}
	short := sessionID
	if len(short) > 8 {
		short = short[:8]
	}
	return Action{Kind: "attach", Short: short, Cwd: cwd}
}

// resolvePane re-derives the tmux pane of a picked row the ledger recorded none
// for, by locating the live agent's process in the current tmux server.
//
// The pane column is not authoritative: it goes NULL for reasons not yet pinned
// down, and an interactive session whose row lost its pane cannot be reached by
// the attach fallback at all. `claude attach` only knows background jobs and
// answers "No job matching <id>", while `tmux new-window` reports the exit status
// of the window creation and not of the command inside it -- so the window opens,
// the command fails, the window closes, and the pick looks like a no-op with
// nothing printed. Walking the process tree recovers the pane instead; measured
// against sessions that did record one, it agrees exactly.
//
// Called for the single picked row only, never for the whole list: roster.List
// costs a subprocess and the panes of rows the user did not select are never
// needed. An unreadable roster leaves the pane empty, which drops back to the
// attach path -- the behaviour before this lookup existed.
func resolvePane(mux multiplexer.Multiplexer, sessionID string) string {
	if sessionID == "" {
		return ""
	}
	agents, err := roster.List()
	if err != nil {
		fmt.Fprintln(os.Stderr, "pane lookup skipped:", err)
		return ""
	}
	return paneForSession(agents, sessionID, mux.FindPane)
}

// paneForSession is the lookup itself, taking the pane finder as an argument so
// the roster-to-pane wiring can be tested without tmux.
func paneForSession(agents []roster.Agent, sessionID string, find func(int) (string, bool)) string {
	for _, a := range agents {
		if a.SessionID != sessionID {
			continue
		}
		if pane, ok := find(a.PID); ok {
			return pane
		}
		// The session is live but outside this tmux server (a session that
		// outlived the server it started in, or a background agent that never
		// had a pane). Looking at later entries cannot help: session ids are
		// unique in the roster.
		return ""
	}
	return ""
}

// Run is the CLI entrypoint for `claude-queue picker`.
func Run(args []string) {
	fs := flag.NewFlagSet("picker", flag.ExitOnError)
	showWorking := fs.Bool("show-working", false, "include working sessions")
	showStale := fs.Bool("show-stale", false, "include stale sessions")
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
	if len(rows) == 0 {
		fmt.Fprintln(os.Stderr, "no active sessions")
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
	if len(fields) < 7 {
		return
	}
	sessionID := strings.TrimSpace(fields[4])
	pane := strings.TrimSpace(fields[5])
	cwd := strings.TrimSpace(fields[6])

	mux := multiplexer.Detect()
	if pane == "" {
		pane = resolvePane(mux, sessionID)
	}
	switch act := DecideAction(sessionID, pane, cwd); act.Kind {
	case "switch":
		if err := mux.Switch(act.Pane); err != nil {
			fmt.Fprintf(os.Stderr, "switch failed (pane likely gone): %v\n", err)
			if termErr := db.TerminateSession(conn, sessionID); termErr != nil {
				fmt.Fprintln(os.Stderr, "terminate:", termErr)
			}
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
	default:
		fmt.Fprintln(os.Stderr, act.Reason)
	}
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
