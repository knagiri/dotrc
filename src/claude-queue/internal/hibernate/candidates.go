// Package hibernate stops the processes of sessions that have sat idle for a
// while, to give their memory back, while leaving their work open: a hibernated
// session is gone, stays listed, and resumes under the same id.
//
// Stopping is safe for the work because it ends in SessionEnd(reason=other),
// which the hook records as gone and never as done. What is NOT safe is
// stopping a session someone is waiting on -- a delegate that asked its
// delegator a question, or a session waiting for an approval -- because the
// answer then has no one to land on. The gates in Candidates exist for that.
package hibernate

import (
	"bufio"
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
	"github.com/knagiri/dotrc/src/claude-queue/internal/roster"
)

// DefaultIdle is how long a session must have sat at idle_done before it is
// hibernated. Long enough that a human stepping away for lunch comes back to
// the same process, short enough that a day's leftovers stop holding memory.
const DefaultIdle = 2 * time.Hour

// Candidate is a session that passed every gate and may be stopped.
type Candidate struct {
	SessionID string
	ConfigDir string
	// Kind is the roster's kind (roster.KindInteractive / KindBackground): it
	// decides how the session is stopped.
	Kind string
	// Pane is the pane the ledger recorded. It is informational only: a
	// recorded pane id can belong to a since-replaced tmux server, so
	// Hibernate re-derives the pane from PID instead of trusting it.
	Pane           string
	Cwd            string
	TranscriptPath string
	PID            int
	// IdleSince is the unix time of the idle_done event the threshold was
	// measured from.
	IdleSince int64
	// Orphan is set when the session's delegator is done or no longer in the
	// ledger, which is why the SendMessage gate was not applied to it.
	Orphan bool
}

// Skip is a running session that was not hibernated, with the gate that held
// it back.
type Skip struct {
	SessionID string
	Reason    string
}

// Candidates returns the open, running sessions that may be hibernated now,
// and a Skip for each one that may not.
//
// A session passes only when all of these hold:
//   - its latest event is idle_done, at least idle old. The ledger is the only
//     record of WHEN the turn ended; the roster has no timestamp for it.
//   - its own config dir's roster lists it with status idle. A dir whose roster
//     cannot be read leaves its sessions alone: an unreadable roster is no
//     evidence of anything.
//   - the last assistant turn of its transcript sent no SendMessage. A delegate
//     that asked its delegator a question also sits at idle, and stopping it
//     leaves the reply with no one to land on. An orphan -- a session whose
//     delegator is done or no longer in the ledger -- is exempt: no reply is
//     coming. A transcript that cannot be read or parsed is a skip, since it
//     is indistinguishable from one holding a pending question.
//
// A pin does not hold a session back. A session waiting on something external
// is exactly the one whose process has nothing to do until that resolves.
func Candidates(conn *sql.DB, now int64, idle time.Duration, list func(dir string) ([]roster.Agent, error), lastTurnSendsMessage func(transcriptPath string) (bool, error)) ([]Candidate, []Skip, error) {
	rows, err := db.ListRows(conn, db.ListOpts{ShowWorking: true, ShowStale: true})
	if err != nil {
		return nil, nil, err
	}
	openIDs, err := db.OpenSessionIDs(conn)
	if err != nil {
		return nil, nil, err
	}
	open := make(map[string]bool, len(openIDs))
	for _, id := range openIDs {
		open[id] = true
	}

	rosters := map[string][]roster.Agent{}
	unreadable := map[string]error{}
	read := func(dir string) ([]roster.Agent, error) {
		if err, ok := unreadable[dir]; ok {
			return nil, err
		}
		if agents, ok := rosters[dir]; ok {
			return agents, nil
		}
		agents, err := list(dir)
		if err != nil {
			unreadable[dir] = err
			return nil, err
		}
		rosters[dir] = agents
		return agents, nil
	}

	var cands []Candidate
	var skips []Skip
	skip := func(id, format string, a ...any) {
		skips = append(skips, Skip{SessionID: id, Reason: fmt.Sprintf(format, a...)})
	}
	for _, r := range rows {
		if r.EffectiveState == db.StateGone {
			continue
		}
		id := r.SessionID
		if r.RawState != "idle_done" {
			skip(id, "latest event is %s, not idle_done", r.RawState)
			continue
		}
		age := time.Duration(now-r.CreatedAt) * time.Second
		if age < idle {
			skip(id, "idle for %s, under the %s threshold", age.Truncate(time.Minute), idle)
			continue
		}
		dir := db.ConfigDirOf(r.ConfigDir)
		agents, err := read(dir)
		if err != nil {
			skip(id, "roster of %s unreadable: %v", dir, err)
			continue
		}
		a, ok := agentFor(agents, id)
		if !ok {
			// reconcile closes these; nothing is running to stop.
			skip(id, "not in the roster of %s", dir)
			continue
		}
		if a.Status != roster.StatusIdle {
			skip(id, "roster status is %q, not idle", a.Status)
			continue
		}
		if a.Kind != roster.KindInteractive && a.Kind != roster.KindBackground {
			skip(id, "unknown kind %q", a.Kind)
			continue
		}
		orphan := r.ParentSessionID.Valid && !open[r.ParentSessionID.String]
		if !orphan {
			if !r.TranscriptPath.Valid || r.TranscriptPath.String == "" {
				skip(id, "no transcript to check for a pending question")
				continue
			}
			sent, err := lastTurnSendsMessage(r.TranscriptPath.String)
			if err != nil {
				skip(id, "transcript unreadable: %v", err)
				continue
			}
			if sent {
				skip(id, "last turn sent a SendMessage (likely awaiting a reply)")
				continue
			}
		}
		cands = append(cands, Candidate{
			SessionID:      id,
			ConfigDir:      dir,
			Kind:           a.Kind,
			Pane:           r.TmuxPane.String,
			Cwd:            r.Cwd.String,
			TranscriptPath: r.TranscriptPath.String,
			PID:            a.PID,
			IdleSince:      r.CreatedAt,
			Orphan:         orphan,
		})
	}
	return cands, skips, nil
}

// agentFor returns the roster entry for id. A session listed more than once
// (it has been observed) is refused: which pid to stop would be a guess.
func agentFor(agents []roster.Agent, id string) (roster.Agent, bool) {
	var found []roster.Agent
	for _, a := range agents {
		if a.SessionID == id {
			found = append(found, a)
		}
	}
	if len(found) != 1 {
		return roster.Agent{}, false
	}
	return found[0], true
}

// transcriptEntry is the part of a transcript line LastTurnSendsMessage reads.
type transcriptEntry struct {
	Type        string `json:"type"`
	IsSidechain bool   `json:"isSidechain"`
	IsMeta      bool   `json:"isMeta"`
	Message     struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type contentBlock struct {
	Type string `json:"type"`
	Name string `json:"name"`
}

// LastTurnSendsMessage reports whether the most recent assistant turn of the
// transcript at path issued a SendMessage tool_use.
//
// A turn is the run of assistant entries after the last real user prompt. Tool
// results also arrive as type "user" entries, so a user entry counts as a
// prompt only when its content is a string or holds something other than a
// tool_result; counting tool results would cut every turn down to its final
// tool call. Sidechain entries are subagent traffic, and isMeta entries (a
// skill's injected preamble, "[Request interrupted by user]") are not
// something a person typed, so neither ends a turn.
//
// The file is read whole, forwards: a turn boundary can only be told from the
// entries after it, and transcripts are small next to the memory a session
// holds. Lines that are not JSON are an error rather than skipped, so a
// corrupt transcript reads as "cannot tell" and holds the session back.
func LastTurnSendsMessage(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	return lastTurnSendsMessage(f)
}

func lastTurnSendsMessage(r io.Reader) (bool, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 64*1024*1024)
	sent := false
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		var e transcriptEntry
		if err := json.Unmarshal(line, &e); err != nil {
			return false, fmt.Errorf("parse transcript: %w", err)
		}
		if e.IsSidechain {
			continue
		}
		switch e.Type {
		case "user":
			if !e.IsMeta && isPrompt(e.Message.Content) {
				sent = false
			}
		case "assistant":
			var blocks []contentBlock
			if json.Unmarshal(e.Message.Content, &blocks) != nil {
				continue
			}
			for _, b := range blocks {
				if b.Type == "tool_use" && b.Name == "SendMessage" {
					sent = true
				}
			}
		}
	}
	if err := sc.Err(); err != nil {
		return false, fmt.Errorf("read transcript: %w", err)
	}
	return sent, nil
}

// isPrompt reports whether a user entry's content is something a person (or a
// delegator) sent, rather than tool results coming back.
func isPrompt(content json.RawMessage) bool {
	var s string
	if json.Unmarshal(content, &s) == nil {
		return true
	}
	var blocks []contentBlock
	if json.Unmarshal(content, &blocks) != nil {
		return false
	}
	for _, b := range blocks {
		if b.Type != "tool_result" {
			return true
		}
	}
	return false
}
