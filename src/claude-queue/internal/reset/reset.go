package reset

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Run is the CLI entrypoint for `claude-queue reset`.
func Run(args []string) {
	fs := flag.NewFlagSet("reset", flag.ExitOnError)
	force := fs.Bool("force", false, "skip confirmation prompt")
	_ = fs.Parse(args)

	path := dbPath()
	if !*force {
		fmt.Fprintf(os.Stderr, "About to delete %s. Continue? [y/N]: ", path)
		r := bufio.NewReader(os.Stdin)
		line, _ := r.ReadString('\n')
		line = strings.TrimSpace(strings.ToLower(line))
		if line != "y" && line != "yes" {
			fmt.Fprintln(os.Stderr, "aborted")
			return
		}
	}

	removed := false
	for _, suffix := range []string{"", "-wal", "-shm"} {
		if err := os.Remove(path + suffix); err == nil {
			removed = true
		}
	}
	if removed {
		fmt.Fprintf(os.Stderr, "removed %s\n", path)
	} else {
		fmt.Fprintf(os.Stderr, "nothing to remove at %s\n", path)
	}
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
