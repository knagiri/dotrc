package summary

import (
	"encoding/json"
	"net/url"
	"path/filepath"
	"strings"

	"github.com/mattn/go-runewidth"
)

// Input is the minimal per-row data needed to render a summary.
type Input struct {
	EffectiveState string
	RawState       string
	Payload        string // raw JSON from events.payload
}

// Summarize returns the picker summary column for a queue row.
func Summarize(in Input) string {
	switch in.EffectiveState {
	case "awaiting_approval":
		return summarizeApproval(in.Payload)
	case "idle_done":
		return summarizeDone(in.Payload)
	case "working":
		return "working"
	case "stale":
		return "stale (was " + in.RawState + ")"
	}
	return in.EffectiveState
}

// TruncateWidth trims s to at most cols terminal columns (double-width chars count 2).
func TruncateWidth(s string, cols int) string {
	return runewidth.Truncate(s, cols, "")
}

func summarizeApproval(payload string) string {
	var p struct {
		ToolName  string          `json:"tool_name"`
		ToolInput json.RawMessage `json:"tool_input"`
	}
	if err := json.Unmarshal([]byte(payload), &p); err != nil || p.ToolName == "" {
		return "awaiting approval"
	}
	detail := toolInputSummary(p.ToolName, p.ToolInput)
	if detail == "" {
		return p.ToolName
	}
	return p.ToolName + ": " + detail
}

func toolInputSummary(tool string, raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var obj map[string]interface{}
	if err := json.Unmarshal(raw, &obj); err != nil {
		return ""
	}
	// TODO(v0.2): handle MCP tool names (mcp__server__tool) per plan §6.
	switch tool {
	case "Bash":
		if cmd, ok := obj["command"].(string); ok {
			return TruncateWidth(strings.TrimSpace(cmd), 30)
		}
	case "Write", "Edit", "MultiEdit", "NotebookEdit":
		if fp, ok := obj["file_path"].(string); ok {
			return filepath.Base(fp)
		}
	case "WebFetch":
		if url, ok := obj["url"].(string); ok {
			return extractHost(url)
		}
	}
	return ""
}

func extractHost(s string) string {
	if u, err := url.Parse(s); err == nil && u.Hostname() != "" {
		return u.Hostname()
	}
	return s
}

func summarizeDone(payload string) string {
	var p struct {
		Last string `json:"last_assistant_message"`
	}
	if err := json.Unmarshal([]byte(payload), &p); err != nil || p.Last == "" {
		return "done"
	}
	flat := strings.ReplaceAll(p.Last, "\n", " ")
	flat = strings.ReplaceAll(flat, "\r", " ")
	return TruncateWidth(strings.TrimSpace(flat), 35)
}
