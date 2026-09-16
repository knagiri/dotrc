// Package configdir answers which CLAUDE_CONFIG_DIR a claude session belongs to.
//
// It exists because the ledger and the things it describes are split along
// different axes. ~/.claude/session-queue.db is keyed off $HOME, so one file
// records every session on the host; the agent roster (`claude agents --json`),
// the daemon that serves it, and the transcripts under projects/ are all per
// config dir. Every tool that matches a ledger row against one of those has to
// know which dir to ask, and a row that does not say is a row that gets matched
// against the wrong roster -- which reads as "that session is gone".
package configdir

import (
	"os"
	"path/filepath"
	"sort"
)

// EnvVar is the variable claude itself reads to pick a config dir, and the one
// every tool here re-exports when it shells out on a row's behalf.
const EnvVar = "CLAUDE_CONFIG_DIR"

// projectsSegment is the directory claude interposes between a config dir and a
// session's transcript: <config dir>/projects/<cwd slug>/<session uuid>.jsonl.
const projectsSegment = "projects"

// Default is the config dir claude uses when CLAUDE_CONFIG_DIR is unset, and
// therefore what a row with nothing recorded is taken to mean -- both the rows
// written before the column existed and the sessions that ran without the env.
func Default() string {
	home, err := os.UserHomeDir()
	if err != nil {
		// Nothing better to name. A relative path keeps the value non-empty so
		// callers still compare and group by it rather than falling into the
		// "" bucket that means "unknown".
		return ".claude"
	}
	return filepath.Join(home, ".claude")
}

// FromTranscript reads the config dir back out of a transcript path, reporting
// false when the path is not in the shape claude writes.
//
// This is the primary source rather than the env, because it is the dir claude
// actually resolved rather than the one its caller's environment happened to
// hold. A hook inherits its env from the claude process, which inherits it from
// whoever started the daemon -- and a background session's daemon is started by
// the first `claude --bg` to need it, whose env is not the delegating session's
// (see dot/claude/rules/worktree-scope.md Sec6). The transcript path comes out
// of the hook payload itself and cannot disagree with where the session's files
// are.
func FromTranscript(transcriptPath string) (string, bool) {
	if transcriptPath == "" {
		return "", false
	}
	projects := filepath.Dir(filepath.Dir(transcriptPath)) // strip <uuid>.jsonl and <slug>
	if filepath.Base(projects) != projectsSegment {
		return "", false
	}
	dir := filepath.Dir(projects)
	if dir == "." || dir == string(filepath.Separator) {
		return "", false
	}
	return dir, true
}

// Resolve picks the config dir to record for a session: its transcript path
// first, the env second, the default last.
//
// envValue is passed in rather than read here so the decision can be asserted
// without touching the process environment. "" means unset.
func Resolve(transcriptPath, envValue string) string {
	if dir, ok := FromTranscript(transcriptPath); ok {
		return dir
	}
	if envValue != "" {
		return filepath.Clean(envValue)
	}
	return Default()
}

// Union returns the known config dirs: whatever the ledger recorded, plus the
// default, deduplicated and sorted.
//
// Including the default unconditionally is what makes a ledger that has never
// seen a second dir -- or one whose rows were all GC'd -- still name the one dir
// that certainly exists. There is deliberately no env listing the others: the
// dirs in use are already written down by the sessions themselves, and a second
// place to spell them is a second place to forget to update, which would drop a
// live dir out of the list silently.
func Union(recorded []string) []string {
	seen := map[string]struct{}{Default(): {}}
	for _, d := range recorded {
		if d == "" {
			continue
		}
		seen[filepath.Clean(d)] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for d := range seen {
		out = append(out, d)
	}
	sort.Strings(out)
	return out
}
