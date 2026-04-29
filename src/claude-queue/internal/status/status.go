package status

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

// order drives the left-to-right layout of the status string.
var order = []string{"awaiting_approval", "idle_done", "working", "stale"}

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

// Format builds the status-right string for tmux.
func Format(counts map[string]int, asciiMode bool) string {
	icons := emoji
	if asciiMode {
		icons = ascii
	}
	var parts []string
	for _, s := range order {
		n := counts[s]
		if n == 0 {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s%d", icons[s], n))
	}
	return strings.Join(parts, " ")
}

// Run is the CLI entrypoint for `claude-queue status`.
// Never returns a non-zero exit: on error prints empty string.
func Run() {
	path := dbPath()
	conn, err := db.Open(path)
	if err != nil {
		return
	}
	defer conn.Close()

	counts, err := db.Counts(conn)
	if err != nil {
		return
	}
	fmt.Print(Format(counts, asciiEnv()))
}

func asciiEnv() bool {
	return os.Getenv("CLAUDE_QUEUE_ASCII") == "1"
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
