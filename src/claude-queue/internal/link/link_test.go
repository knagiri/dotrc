package link

import (
	"io"
	"testing"
)

func TestParseArgs(t *testing.T) {
	const uuid = "1a2b3c4d-1111-2222-3333-444444444444"
	base := []string{"--parent", uuid, "--child", "abcd1234"}
	with := func(extra ...string) []string { return append(append([]string{}, base...), extra...) }
	cases := []struct {
		name         string
		args         []string
		wantErr      bool
		repo, branch string
	}{
		{"valid", base, false, "", ""},
		{"repo and branch", with("--repo", "example-org/example-repo", "--branch", "feat/foo"), false, "example-org/example-repo", "feat/foo"},
		{"branch only", with("--branch", "feat/foo"), false, "", "feat/foo"},
		{"repo not owner/repo", with("--repo", "not-a-repo"), true, "", ""},
		{"repo with host", with("--repo", "github.com/example-org/example-repo"), true, "", ""},
		{"missing parent", []string{"--child", "abcd1234"}, true, "", ""},
		{"empty parent", []string{"--parent", "", "--child", "abcd1234"}, true, "", ""},
		{"missing child", []string{"--parent", uuid}, true, "", ""},
		{"child too short", []string{"--parent", uuid, "--child", "abcd123"}, true, "", ""},
		{"child too long", []string{"--parent", uuid, "--child", "abcd12345"}, true, "", ""},
		{"child uppercase", []string{"--parent", uuid, "--child", "ABCD1234"}, true, "", ""},
		{"child not hex", []string{"--parent", uuid, "--child", "abcd123g"}, true, "", ""},
		{"child full uuid", []string{"--parent", uuid, "--child", uuid}, true, "", ""},
		{"stray positional", with("extra"), true, "", ""},
		{"unknown flag", with("--force"), true, "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			a, err := parseArgs(tc.args, io.Discard)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if tc.wantErr {
				return
			}
			want := linkArgs{Parent: uuid, Child: "abcd1234", Repo: tc.repo, Branch: tc.branch}
			if a != want {
				t.Errorf("got %+v, want %+v", a, want)
			}
		})
	}
}
