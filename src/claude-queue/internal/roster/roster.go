// Package roster reads the live agent roster from `claude agents --json`,
// for one CLAUDE_CONFIG_DIR at a time.
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
	"os"
	"os/exec"

	"github.com/knagiri/dotrc/src/claude-queue/internal/configdir"
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

// ListIn reads the roster of one config dir, by running `claude agents --json`
// with CLAUDE_CONFIG_DIR set to it. "" inherits the environment instead, which
// no caller here wants -- see below -- but is what a bare read would do.
//
// The roster is per config dir because the daemon that answers for it is: each
// dir has its own, and asking one about another dir's sessions returns nothing
// -- indistinguishable, to a caller matching ids, from those sessions having
// ended. Every caller that acts on a session's absence therefore has to ask the
// dir that session actually belongs to, which is why there is no dir-less
// variant of this: the environment a picker popup or a systemd unit carries is
// the tmux server's or the unit's, never the selected session's.
//
// An error is always a failure to read the roster, never "nothing is running":
// reconcile relies on that distinction to avoid terminating every tracked
// session when the command itself breaks.
func ListIn(dir string) ([]Agent, error) {
	cmd := exec.Command("claude", "agents", "--json")
	if dir != "" {
		cmd.Env = append(os.Environ(), configdir.EnvVar+"="+dir)
	}
	out, err := cmd.Output()
	if err != nil {
		if dir != "" {
			return nil, fmt.Errorf("claude agents --json (%s=%s): %w", configdir.EnvVar, dir, err)
		}
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
