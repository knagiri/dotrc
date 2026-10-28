package hook

import (
	"database/sql"
	"testing"

	"github.com/knagiri/dotrc/src/claude-queue/internal/db"
)

func doneAtOf(t *testing.T, d *Deps, id string) sql.NullInt64 {
	t.Helper()
	var at sql.NullInt64
	if err := d.DB.QueryRow("SELECT done_at FROM sessions WHERE session_id = ?", id).Scan(&at); err != nil {
		t.Fatalf("read done_at %s: %v", id, err)
	}
	return at
}

func dispatchAll(t *testing.T, d *Deps, evs ...*Input) {
	t.Helper()
	for _, in := range evs {
		if err := Dispatch(d, in.HookEventName, in); err != nil {
			t.Fatalf("%s %s: %v", in.SessionID, in.HookEventName, err)
		}
	}
}

func start(id, source string) *Input {
	return &Input{SessionID: id, HookEventName: "SessionStart", Source: source}
}

func end(id, reason string) *Input {
	return &Input{SessionID: id, HookEventName: "SessionEnd", Reason: reason}
}

// Leaving the REPL (prompt_input_exit) and /clear (reason clear) end the work.
func TestDispatch_PromptInputExitIsDone(t *testing.T) {
	for _, reason := range []string{"prompt_input_exit", "clear"} {
		t.Run(reason, func(t *testing.T) {
			d := openTestDB(t)
			dispatchAll(t, d, start("s", "startup"), end("s", reason))
			if !doneAtOf(t, d, "s").Valid {
				t.Errorf("reason %s did not mark the session done", reason)
			}
		})
	}
}

// reason "other" is a reboot as much as a `claude stop`: the process is gone,
// the work is not.
func TestDispatch_OtherEndIsGone(t *testing.T) {
	d := openTestDB(t)
	dispatchAll(t, d, start("s", "startup"), end("s", "other"))
	if doneAtOf(t, d, "s").Valid {
		t.Error("reason other marked the session done")
	}
	if !terminatedAt(t, d, "s").Valid {
		t.Error("reason other left terminated_at NULL")
	}
}

func TestDispatch_PrintKindEndIsDone(t *testing.T) {
	d := openTestDB(t)
	d.Kind = db.KindPrint
	dispatchAll(t, d, start("s", "startup"), end("s", "other"))
	if !doneAtOf(t, d, "s").Valid {
		t.Error("a print-mode end did not mark the session done")
	}
	var kind string
	_ = d.DB.QueryRow("SELECT kind FROM sessions WHERE session_id = 's'").Scan(&kind)
	if kind != db.KindPrint {
		t.Errorf("kind = %q, want print", kind)
	}
}

// The kind the hook resolved is recorded, and a later event that knows better
// overwrites it while one that does not leaves it alone.
func TestDispatch_RecordsKind(t *testing.T) {
	d := openTestDB(t)
	d.Kind = db.KindInteractive
	dispatchAll(t, d, start("s", "startup"))
	d.Kind = db.KindBackground
	dispatchAll(t, d, start("s", "resume"))
	d.Kind = ""
	dispatchAll(t, d, &Input{SessionID: "s", HookEventName: "Stop"})
	var kind string
	_ = d.DB.QueryRow("SELECT kind FROM sessions WHERE session_id = 's'").Scan(&kind)
	if kind != db.KindBackground {
		t.Errorf("kind = %q, want background", kind)
	}
}

func TestDispatch_ClearMarksSiblingDone(t *testing.T) {
	d := openTestDB(t)
	d.Pane = "%7"
	dispatchAll(t, d, start("old", "startup"), start("new", "clear"))
	if !doneAtOf(t, d, "old").Valid {
		t.Error("/clear did not mark the replaced session done")
	}
	if doneAtOf(t, d, "new").Valid {
		t.Error("/clear marked the new session done")
	}
}

// A new session in the same pane without /clear (claude quit and run again,
// a resume in that pane) only shows the old process is gone.
func TestDispatch_SamePaneStartupKeepsOldOpen(t *testing.T) {
	d := openTestDB(t)
	d.Pane = "%7"
	dispatchAll(t, d, start("old", "startup"), start("new", "startup"))
	if doneAtOf(t, d, "old").Valid {
		t.Error("a same-pane startup marked the old session done")
	}
	if !terminatedAt(t, d, "old").Valid {
		t.Error("the old session is still running")
	}
}

func TestDispatch_ResumeRevivesGone(t *testing.T) {
	d := openTestDB(t)
	dispatchAll(t, d, start("s", "startup"), end("s", "other"))
	reconcileTerminate(t, d, "s")
	dispatchAll(t, d, start("s", "resume"))
	if at := terminatedAt(t, d, "s"); at.Valid {
		t.Error("resume left the session gone")
	}
	if doneAtOf(t, d, "s").Valid {
		t.Error("resume marked the session done")
	}
	if queueRows(t, d, "s") != 1 {
		t.Error("resumed session is not listed as running")
	}
}

// No hook event takes a done back (only a reopen does): a done session that
// is resumed keeps its done_at and stays out of the listing.
func TestDispatch_ResumeKeepsDone(t *testing.T) {
	d := openTestDB(t)
	dispatchAll(t, d, start("s", "startup"), end("s", "prompt_input_exit"))
	first := doneAtOf(t, d, "s")
	if !first.Valid {
		t.Fatal("fixture: session not done")
	}
	dispatchAll(t, d, start("s", "resume"), &Input{SessionID: "s", HookEventName: "UserPromptSubmit"})
	if got := doneAtOf(t, d, "s"); got != first {
		t.Errorf("done_at = %v after resume, want %v", got, first)
	}
	var n int
	_ = d.DB.QueryRow("SELECT COUNT(*) FROM queue WHERE session_id = 's'").Scan(&n)
	if n != 0 {
		t.Error("a done session is listed after a resume")
	}
}

// Ending a delegator's work ends its delegates' too.
func TestDispatch_DoneCascadesToDelegates(t *testing.T) {
	d := openTestDB(t)
	const parent, child = "aaaaaaaa-0000", "bbbbbbbb-0000"
	dispatchAll(t, d, start(parent, "startup"))
	d.Pane = ""
	dispatchAll(t, d, start(child, "startup"))
	if err := db.LinkSession(d.DB, "bbbbbbbb", parent); err != nil {
		t.Fatal(err)
	}
	dispatchAll(t, d, end(parent, "prompt_input_exit"))
	if !doneAtOf(t, d, child).Valid {
		t.Error("the delegate of a done session is still open")
	}
}
