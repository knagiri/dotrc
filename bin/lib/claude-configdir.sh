# shellcheck shell=bash
#
# claude-configdir.sh -- resolve which CLAUDE_CONFIG_DIR a claude session runs
# under, from the claude-queue ledger.
#
# Sourced by the bin/ tools that shell out on a recorded session's behalf.
#
# The ledger and the things it describes are split along different axes. The
# database path is keyed off $HOME, so one file records every session on the
# host, while the agent roster (`claude agents --json`), the daemon answering it
# and the transcripts under projects/ are all per config dir. So a tool that
# matches a ledger row against any of those has to point its `claude` call at
# the dir that row belongs to -- and cannot read its OWN environment to find out,
# because a tmux popup or a systemd unit carries whatever was set when the
# server or the unit started, not what the session ran under.
#
# There is deliberately no environment variable listing the dirs in use. The
# sessions themselves already write theirs down, and a second place to spell
# them is a second place to forget, which would drop a live dir out of the list
# with no error -- and dropping a dir is exactly the failure being fixed. See
# src/claude-queue/internal/configdir for the same rule on the Go side.
#
# sqlite3 is optional throughout: without it (or without a ledger) every lookup
# answers with the default dir, which is what every session ran under before a
# second one existed. That degrades to the old behaviour rather than to an
# error, and a session in another dir then fails to resolve -- a visible refusal,
# never a wrong session stopped.

# cq_db_path -- the ledger, honouring the same override the Go side reads.
cq_db_path() {
  printf '%s\n' "${CLAUDE_QUEUE_DB:-$HOME/.claude/session-queue.db}"
}

# cq_default_config_dir -- what claude uses with CLAUDE_CONFIG_DIR unset, and
# therefore what a row that recorded nothing is taken to mean.
cq_default_config_dir() {
  printf '%s\n' "$HOME/.claude"
}

# cq_sqlite_available -- true when the ledger can be read at all.
cq_sqlite_available() {
  command -v sqlite3 >/dev/null 2>&1 && [ -f "$(cq_db_path)" ]
}

# cq_config_dirs -- every known config dir, one per line: the ones the ledger
# recorded plus the default, deduplicated and sorted.
#
# Ended rows count, not just live ones: a caller can be asked about a session,
# or a day, that is already over. They are GC'd 7 days after termination, which
# is the one limit of deriving the list this way -- see bin/claude-digest.
cq_config_dirs() {
  {
    cq_default_config_dir
    if cq_sqlite_available; then
      sqlite3 "$(cq_db_path)" \
        "SELECT DISTINCT config_dir FROM sessions WHERE config_dir IS NOT NULL AND config_dir != ''" \
        2>/dev/null || true
    fi
  } | sort -u
}

# cq_config_dir_for <short-id> -- the config dir of the session whose id starts
# with short-id, on stdout.
#
# Exit 0 with the dir when the ledger resolves it to exactly one, or when it
# holds no row for the id at all (the default, matching the Go side's reading of
# an unrecorded row). Exit 2, printing nothing, when rows under DIFFERENT dirs
# share the prefix: the caller cannot be pointed at one dir without guessing,
# and every caller here refuses rather than guess.
#
# Rows under one dir that merely repeat it are not ambiguous, which is why the
# query is DISTINCT over the dir rather than a count of rows -- a session that
# resumed keeps its id, and an id colliding with itself must not read as a
# conflict.
cq_config_dir_for() {
  local short="$1" line out=""
  # The id is spliced into the query, so its shape is checked here rather than
  # trusted from the caller: every caller already validates it, and this keeps
  # the one place that builds SQL from being the place that assumes they did.
  # Anything else answers with the default, which resolves nothing and lets the
  # caller's own refusal do the talking.
  if [[ "$short" =~ ^[0-9a-f]{8}$ ]] && cq_sqlite_available; then
    # A recorded empty string reads as the default, the same as NULL does on
    # the Go side. Substituting here rather than in SQL keeps $HOME out of the
    # query.
    #
    # sqlite3's output is read directly off process substitution rather than
    # captured into a variable and filtered through `grep .` first (which is
    # what this used to do). `grep .` drops blank lines unconditionally --
    # regardless of where they sort in the result set, not only when one
    # happens to land last -- so it drops the row whose dir is the default
    # (COALESCE -> ''), taking that row out of the DISTINCT set the ambiguity
    # check below counts over. A ledger holding one row explicitly pinned to a
    # dir and one row recorded as NULL (-> default) for the SAME 8-char prefix
    # must then read as two distinct dirs and refuse (exit 2); with the blank
    # line filtered out, only the explicit dir survived and the cross-dir case
    # returned it with exit 0 instead of refusing. Skipping `grep .` here lets
    # a blank line arrive as one more (empty) iteration, whatever position it
    # sorts to.
    while IFS= read -r line; do
      [ -n "$line" ] || line="$(cq_default_config_dir)"
      out="$out$line"$'\n'
    done < <(sqlite3 "$(cq_db_path)" \
      "SELECT DISTINCT COALESCE(config_dir, '')
         FROM sessions WHERE substr(session_id, 1, 8) = '$short'" 2>/dev/null || true)
  fi
  out="$(printf '%s' "$out" | sort -u)"

  case "$(printf '%s' "$out" | grep -c .)" in
    0) cq_default_config_dir ;;
    1) printf '%s\n' "$out" ;;
    *) return 2 ;;
  esac
}
