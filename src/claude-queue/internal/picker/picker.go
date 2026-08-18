package picker

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/multiplexer"
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
// Visible columns (--with-nth=1,2,3,4): icon, cwd-basename, summary, age.
// cwd-basename (the worktree dir name) comes right after the icon so it
// starts at a fixed position and stays scannable; the variable-width summary
// is demoted behind it and left untruncated.
// Hidden columns: session_id (5), tmux_pane (6), full cwd (7). The full cwd is
// carried separately from the basename because a background session is opened
// in a new window that needs a real working directory.
func FormatLine(row db.Row, nowSec int64, asciiMode bool) string {
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

	cwdFull := ""
	if row.Cwd.Valid {
		cwdFull = row.Cwd.String
	}

	cwdBase := ""
	if cwdFull != "" {
		cwdBase = filepath.Base(cwdFull)
	}

	age := formatAge(nowSec - row.CreatedAt)

	pane := ""
	if row.TmuxPane.Valid {
		pane = row.TmuxPane.String
	}

	return strings.Join([]string{icon, cwdBase, sum, age, row.SessionID, pane, cwdFull}, "\t")
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

// Run is the CLI entrypoint for `claude-queue picker`.
func Run(args []string) {
	fs := flag.NewFlagSet("picker", flag.ExitOnError)
	showWorking := fs.Bool("show-working", false, "include working sessions")
	showStale := fs.Bool("show-stale", false, "include stale sessions")
	_ = fs.Parse(args)

	conn, err := db.Open(dbPath())
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return
	}
	defer conn.Close()

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
	for _, r := range rows {
		buf.WriteString(FormatLine(r, now, asciiMode))
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
	switch act := DecideAction(sessionID, pane, cwd); act.Kind {
	case "switch":
		if err := mux.Switch(act.Pane); err != nil {
			fmt.Fprintf(os.Stderr, "switch failed (pane likely gone): %v\n", err)
			if termErr := db.TerminateSession(conn, sessionID); termErr != nil {
				fmt.Fprintln(os.Stderr, "terminate:", termErr)
			}
		}
	case "attach":
		// Do NOT terminate the session on failure the way the pane path does:
		// a failed window open says nothing about whether the session is alive,
		// and the manual command still works.
		if err := mux.NewWindow(act.Cwd, []string{"claude", "attach", act.Short}); err != nil {
			fmt.Fprintf(os.Stderr, "run: claude attach %s\n", act.Short)
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

func dbPath() string {
	if p := os.Getenv("CLAUDE_QUEUE_DB"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "session-queue.db"
	}
	return filepath.Join(home, ".claude", "session-queue.db")
}
