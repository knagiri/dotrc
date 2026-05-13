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
	"github.com/mattn/go-runewidth"
)

const cwdWidth = 20

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
// Visible columns (--with-nth=1,2,3,4): icon, summary, cwd-basename, age.
// Hidden columns: session_id (5), tmux_pane (6).
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

	cwdBase := ""
	if row.Cwd.Valid {
		cwdBase = filepath.Base(row.Cwd.String)
		cwdBase = runewidth.Truncate(cwdBase, cwdWidth, "")
	}

	age := formatAge(nowSec - row.CreatedAt)

	pane := ""
	if row.TmuxPane.Valid {
		pane = row.TmuxPane.String
	}

	return strings.Join([]string{icon, sum, cwdBase, age, row.SessionID, pane}, "\t")
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
	if len(fields) < 6 {
		return
	}
	pane := strings.TrimSpace(fields[5])
	if pane == "" {
		fmt.Fprintln(os.Stderr, "no tmux pane recorded for session")
		return
	}
	if err := multiplexer.Detect().Switch(pane); err != nil {
		fmt.Fprintln(os.Stderr, "switch:", err)
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
