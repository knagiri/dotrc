package hook

import (
	"encoding/json"
	"fmt"
	"io"
)

// Input is the JSON payload Claude Code sends on stdin.
// Common fields are set for every event. Optional fields are populated
// only for events that include them.
type Input struct {
	SessionID      string `json:"session_id"`
	TranscriptPath string `json:"transcript_path"`
	Cwd            string `json:"cwd"`
	HookEventName  string `json:"hook_event_name"`
	PermissionMode string `json:"permission_mode"`

	// Event-specific (optional).
	ToolName             string          `json:"tool_name,omitempty"`
	ToolInput            json.RawMessage `json:"tool_input,omitempty"`
	Source               string          `json:"source,omitempty"`
	LastAssistantMessage string          `json:"last_assistant_message,omitempty"`
	Reason               string          `json:"reason,omitempty"`
	Error                string          `json:"error,omitempty"`
}

// ReadInput parses one JSON object from r.
func ReadInput(r io.Reader) (*Input, error) {
	var in Input
	if err := json.NewDecoder(r).Decode(&in); err != nil {
		return nil, fmt.Errorf("decode hook input: %w", err)
	}
	return &in, nil
}
