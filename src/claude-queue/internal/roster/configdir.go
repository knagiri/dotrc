package roster

import (
	"os"
	"path/filepath"
	"strings"
)

// ConfigDir is the config dir claude resolves from the environment:
// $CLAUDE_CONFIG_DIR when set and non-empty, ~/.claude otherwise. It is an
// error when neither is available (no home directory), never a relative
// guess: a caller that cannot tell where claude looks must not act as if it
// could.
func ConfigDir() (string, error) {
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		return dir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".claude"), nil
}

// TranscriptInConfigDir reports whether path lies under <config dir>/projects,
// the only place a `claude --resume` run under this environment looks for a
// session's transcript. A transcript recorded under another config dir can
// exist on disk and still not be found by the resume, which then opens an
// empty session under the same id. It is false when the config dir cannot be
// resolved.
func TranscriptInConfigDir(path string) bool {
	dir, err := ConfigDir()
	if err != nil || path == "" {
		return false
	}
	rel, err := filepath.Rel(filepath.Join(dir, "projects"), path)
	if err != nil {
		return false
	}
	return rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
