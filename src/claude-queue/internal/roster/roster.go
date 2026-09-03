// Package roster reads the live agent roster from `claude agents --json`.
//
// It exists because two callers need the same list for different reasons:
// reconcile treats the roster as the authoritative set of live session ids, and
// the picker needs a picked session's pid to re-derive the tmux pane it runs in.
// Keeping the exec and the JSON contract in one place means the field names are
// stated once.
package roster

import (
	"encoding/json"
	"fmt"
	"os/exec"
)

// The two values Agent.Kind takes. They are named because the distinction
// decides how a session is reached -- an interactive session runs in a tmux
// pane, a background one does not -- so callers branch on it rather than just
// display it.
const (
	KindInteractive = "interactive"
	KindBackground  = "background"
)

// Agent is one entry of the roster. The json tags are the contract with
// `claude agents --json`; fields the callers do not use are left out.
type Agent struct {
	SessionID string `json:"sessionId"`
	PID       int    `json:"pid"`
	Kind      string `json:"kind"` // KindInteractive | KindBackground
	Cwd       string `json:"cwd"`
}

// List runs `claude agents --json` and returns the agents it reports.
//
// An error is always a failure to read the roster, never "nothing is running":
// reconcile relies on that distinction to avoid terminating every tracked
// session when the command itself breaks.
func List() ([]Agent, error) {
	out, err := exec.Command("claude", "agents", "--json").Output()
	if err != nil {
		return nil, fmt.Errorf("claude agents --json: %w", err)
	}
	return parse(out)
}

// parse is split out from List so the JSON contract can be asserted against
// fixture bytes, with no claude binary in the loop.
func parse(data []byte) ([]Agent, error) {
	var agents []Agent
	if err := json.Unmarshal(data, &agents); err != nil {
		return nil, fmt.Errorf("parse roster: %w", err)
	}
	return agents, nil
}
