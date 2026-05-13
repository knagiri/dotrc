package hook

import (
	"strings"
	"testing"
)

func TestReadInput_CommonFields(t *testing.T) {
	raw := `{
		"session_id": "abc123",
		"transcript_path": "/tmp/x.jsonl",
		"cwd": "/work/dir",
		"permission_mode": "default",
		"hook_event_name": "PermissionRequest",
		"tool_name": "Bash",
		"tool_input": {"command": "ls"}
	}`

	in, err := ReadInput(strings.NewReader(raw))
	if err != nil {
		t.Fatalf("ReadInput: %v", err)
	}
	if in.SessionID != "abc123" {
		t.Errorf("SessionID = %q", in.SessionID)
	}
	if in.TranscriptPath != "/tmp/x.jsonl" {
		t.Errorf("TranscriptPath = %q", in.TranscriptPath)
	}
	if in.Cwd != "/work/dir" {
		t.Errorf("Cwd = %q", in.Cwd)
	}
	if in.HookEventName != "PermissionRequest" {
		t.Errorf("HookEventName = %q", in.HookEventName)
	}
	if in.ToolName != "Bash" {
		t.Errorf("ToolName = %q", in.ToolName)
	}
	if len(in.ToolInput) == 0 {
		t.Errorf("ToolInput empty; want raw JSON")
	}
}

func TestReadInput_StopLastMessage(t *testing.T) {
	raw := `{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"done refactoring"}`
	in, err := ReadInput(strings.NewReader(raw))
	if err != nil {
		t.Fatalf("ReadInput: %v", err)
	}
	if in.LastAssistantMessage != "done refactoring" {
		t.Errorf("LastAssistantMessage = %q", in.LastAssistantMessage)
	}
}

func TestReadInput_InvalidJSONReturnsError(t *testing.T) {
	_, err := ReadInput(strings.NewReader("not json"))
	if err == nil {
		t.Error("expected error for invalid JSON")
	}
}
