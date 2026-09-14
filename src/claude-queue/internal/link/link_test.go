package link

import (
	"io"
	"testing"
)

func TestParseArgs(t *testing.T) {
	const uuid = "1a2b3c4d-1111-2222-3333-444444444444"
	cases := []struct {
		name    string
		args    []string
		wantErr bool
	}{
		{"valid", []string{"--parent", uuid, "--child", "abcd1234"}, false},
		{"missing parent", []string{"--child", "abcd1234"}, true},
		{"empty parent", []string{"--parent", "", "--child", "abcd1234"}, true},
		{"missing child", []string{"--parent", uuid}, true},
		{"child too short", []string{"--parent", uuid, "--child", "abcd123"}, true},
		{"child too long", []string{"--parent", uuid, "--child", "abcd12345"}, true},
		{"child uppercase", []string{"--parent", uuid, "--child", "ABCD1234"}, true},
		{"child not hex", []string{"--parent", uuid, "--child", "abcd123g"}, true},
		{"child full uuid", []string{"--parent", uuid, "--child", uuid}, true},
		{"stray positional", []string{"--parent", uuid, "--child", "abcd1234", "extra"}, true},
		{"unknown flag", []string{"--parent", uuid, "--child", "abcd1234", "--force"}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			parent, child, err := parseArgs(tc.args, io.Discard)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if !tc.wantErr && (parent != uuid || child != "abcd1234") {
				t.Errorf("got parent=%q child=%q", parent, child)
			}
		})
	}
}
