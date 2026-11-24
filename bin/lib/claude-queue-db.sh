# shellcheck shell=bash
#
# claude-queue-db.sh -- read the claude-queue ledger from shell.
#
# sqlite3 is optional: without it, or without a ledger, cq_sqlite_available is
# false and the lookups below (cq_kind_for, cq_transcripts_for) fail rather than
# answer.

# cq_db_path -- the ledger, honouring the same override the Go side reads.
cq_db_path() {
  printf '%s\n' "${CLAUDE_QUEUE_DB:-$HOME/.claude/session-queue.db}"
}

# cq_sqlite_available -- true when the ledger can be read at all.
cq_sqlite_available() {
  command -v sqlite3 >/dev/null 2>&1 && [ -f "$(cq_db_path)" ]
}

# cq_kind_for <short-id> -- the kind the ledger recorded for the session whose
# id starts with short-id, on stdout: interactive, background or print. A row
# that recorded none (written before the column existed) reads as interactive,
# the same as on the Go side. "none" when the ledger holds no row for the id,
# "ambiguous" when rows of different kinds share the prefix.
#
# Exit 1, printing nothing, when the ledger cannot be read or the query fails:
# a caller deciding whether it may touch a session must not read a failed
# lookup as "no such session".
cq_kind_for() {
  local short="$1" out
  [[ "$short" =~ ^[0-9a-f]{8}$ ]] || return 1
  cq_sqlite_available || return 1
  out="$(sqlite3 "$(cq_db_path)" \
    "SELECT DISTINCT COALESCE(NULLIF(kind, ''), 'interactive')
       FROM sessions WHERE substr(session_id, 1, 8) = '$short'" 2>/dev/null)" || return 1
  case "$(printf '%s' "$out" | grep -c .)" in
    0) echo none ;;
    1) printf '%s\n' "$out" ;;
    *) echo ambiguous ;;
  esac
}

# cq_transcripts_for <short-id> -- the transcript_path of each ledger row whose
# id starts with short-id, one per line on stdout (rows that recorded none are
# omitted). Nothing is printed for an id the ledger does not hold.
#
# Exit 1, printing nothing, when the ledger cannot be read or the query fails.
cq_transcripts_for() {
  local short="$1"
  [[ "$short" =~ ^[0-9a-f]{8}$ ]] || return 1
  cq_sqlite_available || return 1
  sqlite3 "$(cq_db_path)" \
    "SELECT transcript_path FROM sessions
       WHERE substr(session_id, 1, 8) = '$short' AND COALESCE(transcript_path, '') <> ''" 2>/dev/null
}
