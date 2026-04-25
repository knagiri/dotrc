package state

// States.
const (
	Working          = "working"
	AwaitingApproval = "awaiting_approval"
	IdleDone         = "idle_done"
	Ended            = "ended"
)

// table maps Claude Code hook event names to the resulting state.
var table = map[string]string{
	"SessionStart":       Working,
	"UserPromptSubmit":   Working,
	"PermissionRequest":  AwaitingApproval,
	"PermissionDenied":   Working,
	"PostToolUse":        Working,
	"PostToolUseFailure": Working,
	"Stop":               IdleDone,
	"StopFailure":        IdleDone,
	"SessionEnd":         Ended,
	"ForcedEnd":          Ended, // synthetic (L3 rule)
}

// ForEvent returns the target state and whether the event is known.
func ForEvent(event string) (string, bool) {
	s, ok := table[event]
	return s, ok
}
