package summary

import (
	"encoding/json"
	"net/url"
	"path/filepath"
	"strings"
	"unicode"

	"github.com/mattn/go-runewidth"
)

// summaryWidth caps the two payload-derived summaries in terminal columns.
//
// The summary is rendered last and unpadded, so it has the rest of the popup
// row to itself: the picker opens at 80% of the client width (~290 columns on
// the host this was measured on) and the icon, title and worktree columns
// ahead of it spend under 100 of those. The former 30 and 35 were sized for a
// summary wedged between two variable-width columns, and kept the column from
// using the room the new layout hands it.
const summaryWidth = 150

// Input is the minimal per-row data needed to render a summary.
type Input struct {
	EffectiveState string
	RawState       string
	Payload        string // raw JSON from events.payload
	PriorState     string // resumable rows only: the state before the end
}

// Summarize returns the picker summary column for a queue row.
//
// The result never carries a tab, a newline or a carriage return. The picker's
// rows are tab-delimited and hold the session id, pane, cwd and transcript
// path in hidden columns behind the summary, so a separator smuggled in
// through a payload shifts all four and the pick acts on another session's id
// and working directory. Bash commands reach here verbatim and a literal tab
// in one is ordinary (`awk -F'<tab>'`), so this is a live path rather than a
// theoretical one. The guard sits on the way out so it covers every branch,
// including the ones that pass a payload string through untouched.
func Summarize(in Input) string {
	return flatten(summarize(in))
}

// flatten replaces the row separators with a space and drops the remaining
// control characters -- a control character is not a word boundary, so
// substituting one would invent a space that was not in the payload.
func flatten(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r == '\t' || r == '\n' || r == '\r':
			b.WriteByte(' ')
		case unicode.IsControl(r):
		default:
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}

func summarize(in Input) string {
	switch in.EffectiveState {
	case "awaiting_approval":
		return summarizeApproval(in.Payload)
	case "idle_done":
		return summarizeDone(in.Payload)
	case "working":
		return "working"
	case "stale":
		return "stale (was " + in.RawState + ")"
	case "resumable":
		return summarizeResumable(in.PriorState)
	}
	return in.EffectiveState
}

// summarizeResumable names what the session was doing when it was cut off,
// which is the one thing that distinguishes these rows from each other: the
// payload of an end event carries only its reason, and the raw state is 'ended'
// for all of them. A session whose only recorded event is the end has no prior
// state to report.
func summarizeResumable(prior string) string {
	if prior == "" {
		return "resumable"
	}
	return "resumable (was " + prior + ")"
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
			// Flattened before the cut, not only by Summarize on the way out:
			// runewidth gives a control character width 0, so a command full of
			// tabs would spend none of the budget here and then widen past it
			// once each tab became a space.
			return TruncateWidth(flatten(cmd), summaryWidth)
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
	// Flattened before the cut for the same reason as the Bash command above.
	return TruncateWidth(flatten(p.Last), summaryWidth)
}
