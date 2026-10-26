package hook

import "github.com/knagiri/dotrc/src/claude-queue/internal/db"

// KindFromEnv decides how the session firing the hook was started, from the
// environment claude hands its hooks.
//
// The SessionEnd reason cannot answer it: `claude -p` finishing, `claude stop`,
// a killed pane and a host shutdown all end with reason "other". The
// environment does, as measured on each kind's SessionStart:
//
//	                         interactive  background (--bg)    print (-p)
//	CLAUDE_CODE_ENTRYPOINT   cli          cli                  sdk-cli
//	CLAUDE_JOB_DIR           unset        <config>/jobs/<id>   unset
//
// The sdk-cli entrypoint is checked first. CLAUDE_JOB_DIR is inherited by
// child processes, so a `claude -p` started from a background job's Bash tool
// carries it too; checking it first would record that print run as background,
// which is never marked done at exit and piles up as gone. No background job
// has the sdk-cli entrypoint (the table above), so the order costs the measured
// cases nothing. CLAUDE_JOB_DIR is then the one variable that tells a
// background job from an interactive session.
func KindFromEnv(getenv func(string) string) string {
	if getenv("CLAUDE_CODE_ENTRYPOINT") == "sdk-cli" {
		return db.KindPrint
	}
	if getenv("CLAUDE_JOB_DIR") != "" {
		return db.KindBackground
	}
	return db.KindInteractive
}
