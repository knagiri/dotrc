package roster

import "testing"

// The fixture is trimmed real output of `claude agents --json`: the field names
// here are the only thing standing between the picker and a zero pid.
const fixture = `[
  {
    "pid": 2249851,
    "cwd": "/home/x/ghq/github.com/knagiri/dotrc",
    "kind": "interactive",
    "startedAt": 1776422217714,
    "sessionId": "2d6f9783-fc23-4dbf-ba51-5c7d1c1a4804"
  },
  {
    "pid": 198617,
    "cwd": "/home/x/ghq/github.com/knagiri/dotrc_wt",
    "kind": "background",
    "startedAt": 1781669179831,
    "sessionId": "7a1fe262-2f1a-458c-b9bb-ca3d777d9d45",
    "status": "idle"
  }
]`

func TestParse(t *testing.T) {
	agents, err := parse([]byte(fixture))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(agents) != 2 {
		t.Fatalf("len = %d, want 2", len(agents))
	}
	want := Agent{
		SessionID: "2d6f9783-fc23-4dbf-ba51-5c7d1c1a4804",
		PID:       2249851,
		Kind:      "interactive",
		Cwd:       "/home/x/ghq/github.com/knagiri/dotrc",
	}
	if agents[0] != want {
		t.Errorf("agents[0] = %+v, want %+v", agents[0], want)
	}
	if agents[1].Kind != "background" || agents[1].PID != 198617 {
		t.Errorf("agents[1] = %+v, want the background entry with pid 198617", agents[1])
	}
}

func TestParse_Empty(t *testing.T) {
	agents, err := parse([]byte(`[]`))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(agents) != 0 {
		t.Errorf("len = %d, want 0", len(agents))
	}
}

// Garbage must surface as an error, not as an empty roster: reconcile terminates
// everything tracked when handed an empty one.
func TestParse_Invalid(t *testing.T) {
	if _, err := parse([]byte(`not json`)); err == nil {
		t.Error("parse err = nil, want non-nil")
	}
}
