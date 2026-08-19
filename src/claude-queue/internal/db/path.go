package db

import (
	"os"
	"path/filepath"
)

// DefaultPath is where the queue database lives. CLAUDE_QUEUE_DB overrides it,
// which is how the shell tests and bin/claude-reap-bg point at a fixture
// database instead of the real one.
func DefaultPath() string {
	if p := os.Getenv("CLAUDE_QUEUE_DB"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "session-queue.db"
	}
	return filepath.Join(home, ".claude", "session-queue.db")
}
