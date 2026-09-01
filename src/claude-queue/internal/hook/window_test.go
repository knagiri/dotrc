package hook

import (
	"os"
	"path/filepath"
	"testing"
)

// recordingMux is a windowMux that answers from fixed values and records what
// was asked of it, so the guard can be exercised without a tmux server.
type recordingMux struct {
	paneCount   int
	paneCountOK bool
	windowName  string
	windowOK    bool

	renamed   []string // names passed to RenameWindow
	automatic []bool   // values passed to SetAutomaticRename
}

func (m *recordingMux) RenameWindow(pane, name string) error {
	m.renamed = append(m.renamed, name)
	return nil
}

func (m *recordingMux) SetAutomaticRename(pane string, on bool) error {
	m.automatic = append(m.automatic, on)
	return nil
}

func (m *recordingMux) WindowName(pane string) (string, bool) {
	return m.windowName, m.windowOK
}

func (m *recordingMux) WindowPaneCount(pane string) (int, bool) {
	return m.paneCount, m.paneCountOK
}

// solePane is the ordinary case: one claude session, one pane, one window.
func solePane() *recordingMux {
	return &recordingMux{paneCount: 1, paneCountOK: true}
}

const (
	testSessionID  = "6773febd-ce31-4e22-8354-5bc0d72c18a1"
	testWindowName = "Docs-Lint-判断-6773febd"
)

func titledTranscript(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	line := `{"type":"ai-title","aiTitle":"Docs Lint 判断","sessionId":"` + testSessionID + `"}` + "\n"
	if err := os.WriteFile(path, []byte(line), 0600); err != nil {
		t.Fatalf("write transcript: %v", err)
	}
	return path
}

func TestApplyWindowName_RenamesOnPromptAndStop(t *testing.T) {
	// Stop matters as much as UserPromptSubmit: the ai-title is written right
	// after the first answer, so without Stop a session would keep its
	// fallback name until the user typed a second prompt.
	for _, event := range []string{"UserPromptSubmit", "Stop"} {
		t.Run(event, func(t *testing.T) {
			mux := solePane()
			applyWindowName(mux, event, "%1", titledTranscript(t), testSessionID)
			if len(mux.renamed) != 1 || mux.renamed[0] != testWindowName {
				t.Errorf("renamed = %v, want [%q]", mux.renamed, testWindowName)
			}
		})
	}
}

func TestApplyWindowName_LeavesOtherEventsAlone(t *testing.T) {
	// PostToolUse and friends fire many times a turn and would only re-derive
	// the same name, at the cost of a tmux call each.
	for _, event := range []string{"SessionStart", "PostToolUse", "PermissionRequest"} {
		t.Run(event, func(t *testing.T) {
			mux := solePane()
			applyWindowName(mux, event, "%1", titledTranscript(t), testSessionID)
			if len(mux.renamed) != 0 || len(mux.automatic) != 0 {
				t.Errorf("%s touched the window: renamed=%v automatic=%v", event, mux.renamed, mux.automatic)
			}
		})
	}
}

func TestApplyWindowName_Guards(t *testing.T) {
	tests := []struct {
		name string
		mux  *recordingMux
		pane string
	}{
		{
			// A background session has no pane of its own, so there is no
			// window it can claim.
			name: "no pane",
			mux:  solePane(),
			pane: "",
		},
		{
			// Two sessions split side by side would flip the shared window's
			// name between two topics on every prompt.
			name: "the window holds another pane",
			mux:  &recordingMux{paneCount: 2, paneCountOK: true},
			pane: "%1",
		},
		{
			// An unanswerable count is not evidence the pane is alone, and
			// the guard exists precisely to avoid taking a name that is not
			// this session's to take.
			name: "the pane count could not be read",
			mux:  &recordingMux{paneCount: 1, paneCountOK: false},
			pane: "%1",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			applyWindowName(tt.mux, "UserPromptSubmit", tt.pane, titledTranscript(t), testSessionID)
			if len(tt.mux.renamed) != 0 {
				t.Errorf("renamed = %v, want no rename", tt.mux.renamed)
			}
		})
	}
}

func TestApplyWindowName_UntitledTranscriptKeepsTheCurrentName(t *testing.T) {
	// Before the first prompt is written there is nothing to name the window
	// after, and an empty rename would be worse than the name it has.
	mux := solePane()
	applyWindowName(mux, "UserPromptSubmit", "%1", filepath.Join(t.TempDir(), "absent.jsonl"), testSessionID)
	if len(mux.renamed) != 0 {
		t.Errorf("renamed = %v, want no rename", mux.renamed)
	}
}

func TestApplyWindowName_SessionEnd(t *testing.T) {
	transcript := titledTranscript(t)

	t.Run("hands the name back when it is ours", func(t *testing.T) {
		// rename-window disables tmux's automatic-rename permanently, so a
		// session that named its window has to give it back or the title of a
		// finished conversation sits on top of the user's shell forever.
		mux := &recordingMux{windowName: testWindowName, windowOK: true}
		applyWindowName(mux, "SessionEnd", "%1", transcript, testSessionID)
		if len(mux.automatic) != 1 || !mux.automatic[0] {
			t.Errorf("automatic = %v, want [true]", mux.automatic)
		}
	})

	t.Run("leaves a name we did not set", func(t *testing.T) {
		// A window the user renamed by hand, or one the picker's exit rename
		// has already moved aside, keeps the name it has.
		for _, current := range []string{"my-own-name", testWindowName + "~exited", ""} {
			mux := &recordingMux{windowName: current, windowOK: true}
			applyWindowName(mux, "SessionEnd", "%1", transcript, testSessionID)
			if len(mux.automatic) != 0 {
				t.Errorf("window named %q: automatic = %v, want untouched", current, mux.automatic)
			}
		}
	})

	t.Run("an unreadable window name changes nothing", func(t *testing.T) {
		mux := &recordingMux{windowName: testWindowName, windowOK: false}
		applyWindowName(mux, "SessionEnd", "%1", transcript, testSessionID)
		if len(mux.automatic) != 0 {
			t.Errorf("automatic = %v, want untouched", mux.automatic)
		}
	})
}
