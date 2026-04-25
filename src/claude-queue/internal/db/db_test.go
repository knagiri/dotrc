package db

import (
	"path/filepath"
	"testing"
)

func TestOpenAppliesSchemaAndPragmas(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")

	conn, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer conn.Close()

	var jm string
	if err := conn.QueryRow("PRAGMA journal_mode").Scan(&jm); err != nil {
		t.Fatalf("journal_mode pragma: %v", err)
	}
	if jm != "wal" {
		t.Errorf("journal_mode = %q, want %q", jm, "wal")
	}

	// sessions / events / queue should exist.
	wantObjects := []string{"sessions", "events", "queue"}
	for _, name := range wantObjects {
		var got string
		err := conn.QueryRow(
			"SELECT name FROM sqlite_master WHERE name = ?", name,
		).Scan(&got)
		if err != nil {
			t.Errorf("object %q not found: %v", name, err)
		}
	}
}

func TestOpenIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")

	for i := 0; i < 3; i++ {
		conn, err := Open(path)
		if err != nil {
			t.Fatalf("Open iter %d: %v", i, err)
		}
		conn.Close()
	}
}
