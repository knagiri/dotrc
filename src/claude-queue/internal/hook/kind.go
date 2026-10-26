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
// CLAUDE_JOB_DIR is checked first: it exists only for a background job, and
// is the one variable that tells it from an interactive session.
func KindFromEnv(getenv func(string) string) string {
	if getenv("CLAUDE_JOB_DIR") != "" {
		return db.KindBackground
	}
	if getenv("CLAUDE_CODE_ENTRYPOINT") == "sdk-cli" {
		return db.KindPrint
	}
	return db.KindInteractive
}
