package picker

// The picker's resume-window conventions, for the other path that resumes a
// session into a fresh tmux window: the watch pass waking a session for its PR watch
// (package prwatch). Both have to open the window in the same place and under
// the same name, or a pick after a wake-up would open a second window for the
// same session.

// SessionName is the tmux session a resumed session's window opens in: the
// canonical name of the worktree holding cwd.
func SessionName(cwd string) string { return worktreeName(cwd) }

// ResumeWindowName is the name of the window a resume opens.
func ResumeWindowName(transcript, sessionID string) string {
	return windowNameFor(transcript, sessionID, "resume")
}
