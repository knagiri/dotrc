package hook

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/multiplexer"
)

// Run is the CLI entrypoint for `claude-queue hook <event>`.
// It NEVER returns a non-zero exit — callers should os.Exit(0) after.
// Errors go to the debug log when CLAUDE_QUEUE_DEBUG=1.
func Run(event string) {
	in, err := ReadInput(os.Stdin)
	if err != nil {
		logDebug("read input: %v", err)
		return
	}

	// Cross-check argv vs stdin; argv wins.
	if in.HookEventName != "" && in.HookEventName != event {
		logDebug("event mismatch: argv=%s stdin=%s (argv wins)", event, in.HookEventName)
	}

	path := dbPath()
	conn, err := db.Open(path)
	if err != nil {
		logDebug("db.Open(%s): %v", path, err)
		return
	}
	defer conn.Close()

	mux := multiplexer.Detect()
	d := &Deps{DB: conn, Pane: mux.PaneID()}
	if err := Dispatch(d, event, in); err != nil {
		logDebug("dispatch %s: %v", event, err)
		return
	}
	mux.RefreshStatus()
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

func logDebug(format string, args ...interface{}) {
	if os.Getenv("CLAUDE_QUEUE_DEBUG") != "1" {
		return
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	path := filepath.Join(home, ".claude", "session-queue.log")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, format+"\n", args...)
}
