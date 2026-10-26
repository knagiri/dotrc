package picker

// The picker's resume-window conventions, for the other path that resumes a
// session into a fresh tmux window: the watch pass waking a pinned session
// (package prwatch). Both have to open the window in the same place, under the
// same name and with the same config dir, or a pick after a wake-up would open
// a second window for the same session.

// SessionName is the tmux session a resumed session's window opens in: the
// canonical name of the worktree holding cwd.
func SessionName(cwd string) string { return worktreeName(cwd) }

// ResumeWindowName is the name of the window a resume opens.
func ResumeWindowName(transcript, sessionID string) string {
	return windowNameFor(transcript, sessionID, "resume")
}

// LaunchIn is the -e env and the argv that run argv under configDir in a tmux
// window (see actionLaunch).
func LaunchIn(configDir string, argv []string) (map[string]string, []string) {
	return actionLaunch(Action{ConfigDir: configDir}, argv)
}
