package db

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

// Open opens the SQLite database at path, applies PRAGMAs, schema and
// migrations. The returned *sql.DB is safe for concurrent use.
//
// The order is load-bearing: Tables first so a fresh database has them,
// migrate() second so an existing one gains the columns CREATE TABLE IF NOT
// EXISTS cannot add, and View last because it selects a column that only exists
// after the migration.
func Open(path string) (*sql.DB, error) {
	conn, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("sql.Open: %w", err)
	}

	for _, p := range Pragmas {
		if _, err := conn.Exec(p); err != nil {
			conn.Close()
			return nil, fmt.Errorf("pragma %q: %w", p, err)
		}
	}

	for _, step := range []struct {
		what string
		run  func(*sql.DB) error
	}{
		{"apply tables", func(c *sql.DB) error { _, err := c.Exec(Tables); return err }},
		{"migrate", migrate},
		{"apply view", func(c *sql.DB) error { _, err := c.Exec(View); return err }},
	} {
		if err := step.run(conn); err != nil {
			conn.Close()
			return nil, fmt.Errorf("%s: %w", step.what, err)
		}
	}

	return conn, nil
}

// migrate brings an existing database up to the current Tables definition.
//
// Only added columns so far, which SQLite can do in place. ALTER TABLE ... ADD
// COLUMN errors when the column is already there and SQLite has no IF NOT
// EXISTS for it, so each one is asked for first -- Open runs on every hook
// invocation, and a migration that fails on the second run would take the whole
// ledger down with it.
func migrate(conn *sql.DB) error {
	for _, m := range []struct{ table, column, ddl string }{
		{"sessions", "config_dir", "ALTER TABLE sessions ADD COLUMN config_dir TEXT"},
	} {
		has, err := hasColumn(conn, m.table, m.column)
		if err != nil {
			return err
		}
		if has {
			continue
		}
		if _, err := conn.Exec(m.ddl); err != nil {
			return fmt.Errorf("add %s.%s: %w", m.table, m.column, err)
		}
	}
	return nil
}

// hasColumn reports whether table already has column, via pragma_table_info --
// the table-valued form, so the answer comes back as a row that can be counted
// rather than a result set to scan.
func hasColumn(conn *sql.DB, table, column string) (bool, error) {
	var n int
	if err := conn.QueryRow(
		"SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?", table, column,
	).Scan(&n); err != nil {
		return false, fmt.Errorf("inspect %s.%s: %w", table, column, err)
	}
	return n > 0, nil
}
