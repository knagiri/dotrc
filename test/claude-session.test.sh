#!/usr/bin/env bash
# Functional tests for claude-session. Two fake hosts each get their own
# CLAUDE_CONFIG_DIR and ghq root under a temp dir; `ghq` is a PATH stub whose
# `root` prints $GHQ_STUB_ROOT. Every fixture (transcripts, archives) is built
# here, so the real ~/.claude is never read or written.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
src="$here/../bin/claude-session"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT

stubbin="$tmp/stubbin"
mkdir -p "$stubbin"
cat >"$stubbin/ghq" <<'EOF'
#!/usr/bin/env bash
[ "$1" = root ] || exit 2
printf '%s\n' "$GHQ_STUB_ROOT"
EOF
chmod +x "$stubbin/ghq"

ok() { echo "ok: $1"; }
ng() { echo "FAIL: $1"; fail=1; }

id=11111111-2222-3333-4444-555555555555
repo=github.com/example-org/example-repo

# Host A and host B: different "homes", different ghq roots.
cfg_a="$tmp/a/home/.claude"; root_a="$tmp/a/home/ghq"
cfg_b="$tmp/b/users/other/.claude"; root_b="$tmp/b/users/other/src"
mkdir -p "$root_a/$repo/.worktrees/feature-foo" "$root_b/$repo"

run_a() { PATH="$stubbin:$PATH" CLAUDE_CONFIG_DIR="$cfg_a" GHQ_STUB_ROOT="$root_a" "$src" "$@"; }
run_b() { PATH="$stubbin:$PATH" CLAUDE_CONFIG_DIR="$cfg_b" GHQ_STUB_ROOT="$root_b" "$src" "$@"; }

# Expected projects/ dir name, written independently of the script.
enc() { local p="$1"; p="${p//\//-}"; printf '%s\n' "${p//./-}"; }

# make_session <cfg> <cwd> <id>: a transcript whose first line has a null cwd
# (as summary lines do), so the script must skip to the first real one.
make_session() {
  local d
  d="$1/projects/$(enc "$2")"
  mkdir -p "$d"
  {
    printf '{"type":"summary","cwd":null,"sessionId":"%s"}\n' "$3"
    printf '{"type":"user","cwd":"%s","sessionId":"%s","message":"hello"}\n' "$2" "$3"
    printf '{"type":"assistant","cwd":"%s","session_id":"%s","message":"hi"}\n' "$2" "$3"
  } >"$d/$3.jsonl"
  printf '%s\n' "$d"
}

reset_b() { rm -rf "$cfg_b"; }

# --- round trip across ghq roots, with the <id>/ side directory -----------
src_dir="$(make_session "$cfg_a" "$root_a/$repo" "$id")"
mkdir -p "$src_dir/$id/tool-results" "$src_dir/$id/subagents"
printf 'tool output\n' >"$src_dir/$id/tool-results/b3nvyyzrc.txt"
printf '{}\n' >"$src_dir/$id/subagents/agent-a0b7a60e.jsonl"

arch="$tmp/s.tar.gz"
err="$(run_a export "$id" -o "$arch" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$arch" ] && grep -qi secret <<<"$err"; then
  ok "export writes the archive and warns about secrets"
else ng "export rc=$rc err=$err"; fi

out="$(run_b import "$arch" 2>/dev/null)"; rc=$?
dest="$cfg_b/projects/$(enc "$root_b/$repo")"
if [ "$rc" -eq 0 ] && cmp -s "$src_dir/$id.jsonl" "$dest/$id.jsonl"; then
  ok "import places a byte-identical jsonl under the destination cwd's <enc>"
else ng "round trip rc=$rc dest=$dest; ls: $(ls -R "$cfg_b" 2>&1)"; fi
if diff -r "$src_dir/$id" "$dest/$id" >/dev/null 2>&1; then
  ok "the <id>/ side directory travels with the transcript"
else ng "side dir not carried: $(diff -r "$src_dir/$id" "$dest/$id" 2>&1)"; fi
if [ "$out" = "cd $root_b/$repo && claude --resume $id" ]; then
  ok "import prints the resume command"
else ng "resume hint: $out"; fi

# --- the same id imported again is refused, existing file untouched --------
printf 'local edit\n' >>"$dest/$id.jsonl"
before="$(cksum <"$dest/$id.jsonl")"
err="$(run_b import "$arch" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(cksum <"$dest/$id.jsonl")" = "$before" ] && grep -q 'already exists' <<<"$err"; then
  ok "an id already under projects/ is refused, not overwritten"
else ng "collision rc=$rc err=$err"; fi
# ...even when it sits under a different <enc>.
reset_b; mkdir -p "$cfg_b/projects/-elsewhere"; printf 'x\n' >"$cfg_b/projects/-elsewhere/$id.jsonl"
run_b import "$arch" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$dest/$id.jsonl" ]; then
  ok "an id existing under another projects/ dir is refused too"
else ng "collision elsewhere rc=$rc"; fi

# --- existing output path is not overwritten ------------------------------
printf 'keep\n' >"$tmp/exists.tar.gz"
run_a export "$id" -o "$tmp/exists.tar.gz" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$tmp/exists.tar.gz")" = keep ]; then
  ok "export refuses an existing output path"
else ng "existing output rc=$rc"; fi
# The default output name lands in the current directory.
(cd "$tmp" && run_a export "$id" >/dev/null 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$tmp/claude-session-$id.tar.gz" ]; then
  ok "default output is ./claude-session-<id>.tar.gz"
else ng "default output rc=$rc"; fi

# --- worktree subpath -----------------------------------------------------
wid=22222222-3333-4444-5555-666666666666
make_session "$cfg_a" "$root_a/$repo/.worktrees/feature-foo" "$wid" >/dev/null
run_a export "$wid" -o "$tmp/w.tar.gz" >/dev/null 2>&1
meta_sub="$(tar -xzOf "$tmp/w.tar.gz" meta.json | jq -r .subpath)"
meta_repo="$(tar -xzOf "$tmp/w.tar.gz" meta.json | jq -r .repo)"
if [ "$meta_sub" = .worktrees/feature-foo ] && [ "$meta_repo" = "$repo" ]; then
  ok "meta.json splits repo and worktree subpath"
else ng "meta repo=$meta_repo subpath=$meta_sub"; fi
reset_b
err="$(run_b import "$tmp/w.tar.gz" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'does not exist' <<<"$err" && [ ! -d "$cfg_b/projects" ]; then
  ok "a missing destination subpath is refused"
else ng "missing subpath rc=$rc err=$err"; fi
mkdir -p "$root_b/$repo/.worktrees/feature-foo"
run_b import "$tmp/w.tar.gz" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$cfg_b/projects/$(enc "$root_b/$repo/.worktrees/feature-foo")/$wid.jsonl" ]; then
  ok "a worktree session lands under the destination worktree's <enc>"
else ng "worktree import rc=$rc; ls: $(ls "$cfg_b/projects" 2>&1)"; fi

# --- export refusals ------------------------------------------------------
oid=33333333-4444-5555-6666-777777777777
make_session "$cfg_a" "$tmp/a/home/scratch/proj" "$oid" >/dev/null
err="$(run_a export "$oid" -o "$tmp/o.tar.gz" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/o.tar.gz" ] && grep -q 'not under ghq root' <<<"$err"; then
  ok "a cwd outside ghq root is refused"
else ng "outside ghq rc=$rc err=$err"; fi

# A cwd directly in a host or owner dir is not inside a repo.
sid=66666666-7777-8888-9999-000000000000
make_session "$cfg_a" "$root_a/github.com/example-org" "$sid" >/dev/null
run_a export "$sid" -o "$tmp/sh.tar.gz" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/sh.tar.gz" ]; then
  ok "a cwd above the repo level is refused"
else ng "shallow cwd rc=$rc"; fi

uid=44444444-5555-6666-7777-888888888888
mkdir -p "$cfg_a/projects/-x"
printf '{"cwd":"%s","sessionId":"%s"}\n' "$root_a/github.com/example-org/example_repo" "$uid" >"$cfg_a/projects/-x/$uid.jsonl"
err="$(run_a export "$uid" -o "$tmp/u.tar.gz" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/u.tar.gz" ] && grep -q 'unverified' <<<"$err"; then
  ok "a cwd with characters of unverified encoding is refused"
else ng "underscore cwd rc=$rc err=$err"; fi

# A transcript by that name exists and is otherwise exportable, so only the
# id check can refuse it. A glob such as `*` is the dangerous form: it would
# match whatever single transcript a config dir holds.
mkdir -p "$cfg_a/projects/-nu"
printf '{"cwd":"%s"}\n' "$root_a/$repo" >"$cfg_a/projects/-nu/not-a-uuid.jsonl"
run_a export not-a-uuid -o "$tmp/n.tar.gz" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/n.tar.gz" ]; then ok "a non-uuid session id is refused"
else ng "non-uuid rc=$rc"; fi
rm -rf "$cfg_a/projects/-nu"

run_a export 99999999-9999-9999-9999-999999999999 -o "$tmp/m.tar.gz" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/m.tar.gz" ]; then ok "an unknown session id is refused"
else ng "unknown id rc=$rc"; fi

mkdir -p "$cfg_a/projects/-dup"; cp "$src_dir/$id.jsonl" "$cfg_a/projects/-dup/"
err="$(run_a export "$id" -o "$tmp/d.tar.gz" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/d.tar.gz" ] && grep -q 'want exactly one' <<<"$err"; then
  ok "an id found under two projects/ dirs is refused"
else ng "duplicate rc=$rc err=$err"; fi
rm -rf "$cfg_a/projects/-dup"

# --- hostile archives -----------------------------------------------------
# Each is built by hand from a clean stage, then altered one way. The import
# must fail, place nothing, and write nothing outside the extraction dir.
mkstage() {
  local s="$tmp/stage.$1"
  rm -rf "$s"; mkdir -p "$s/$id/tool-results"
  cp "$src_dir/$id.jsonl" "$s/"
  printf 'x\n' >"$s/$id/tool-results/t.txt"
  jq -n --arg s "$id" --arg r "$repo" '{format:1, session_id:$s, repo:$r, subpath:""}' >"$s/meta.json"
  printf '%s\n' "$s"
}
expect_reject() { # <label> <archive>
  local err rc
  reset_b
  err="$(run_b import "$2" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$(find "$cfg_b" -name "$id*" 2>/dev/null)" ] && [ ! -e "$tmp/escaped" ]; then
    ok "hostile archive rejected: $1"
  else ng "hostile archive accepted ($1) rc=$rc err=$err"; fi
  rm -f "$tmp/escaped"
}

# The clean stage itself must import, or every rejection below proves nothing.
s="$(mkstage clean)"; tar -czf "$tmp/h-clean.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
reset_b
if run_b import "$tmp/h-clean.tar.gz" >/dev/null 2>&1 && [ -f "$dest/$id.jsonl" ]; then
  ok "control: the hand-built clean archive imports"
else ng "control: hand-built clean archive did not import"; fi

s="$(mkstage dotdot)"; printf 'pwn\n' >"$s/escaped"
tar -czf "$tmp/h-dotdot.tar.gz" -P -C "$s" --transform "s,^escaped\$,$id/../../escaped," meta.json "$id.jsonl" "$id" escaped
expect_reject "member with .." "$tmp/h-dotdot.tar.gz"

s="$(mkstage abs)"; printf 'pwn\n' >"$tmp/abs-src"
tar -czf "$tmp/h-abs.tar.gz" -P -C "$s" meta.json "$id.jsonl" "$id" "$tmp/abs-src"
expect_reject "absolute member" "$tmp/h-abs.tar.gz"

s="$(mkstage link)"; ln -s /etc/passwd "$s/$id/tool-results/l.txt"
tar -czf "$tmp/h-link.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
expect_reject "symlink member" "$tmp/h-link.tar.gz"

s="$(mkstage hard)"; ln "$s/$id/tool-results/t.txt" "$s/$id/tool-results/h.txt"
tar -czf "$tmp/h-hard.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
expect_reject "hard link member" "$tmp/h-hard.tar.gz"

s="$(mkstage extra)"; printf 'x\n' >"$s/extra.txt"
tar -czf "$tmp/h-extra.tar.gz" -C "$s" meta.json "$id.jsonl" "$id" extra.txt
expect_reject "unexpected top-level file" "$tmp/h-extra.tar.gz"

s="$(mkstage hidden)"; printf 'x\n' >"$s/$id/.hidden"
tar -czf "$tmp/h-hidden.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
expect_reject "hidden component" "$tmp/h-hidden.tar.gz"

s="$(mkstage mismatch)"
jq -n --arg r "$repo" '{format:1, session_id:"55555555-6666-7777-8888-999999999999", repo:$r, subpath:""}' >"$s/meta.json"
tar -czf "$tmp/h-mismatch.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
expect_reject "meta session_id differs from file name" "$tmp/h-mismatch.tar.gz"

s="$(mkstage badid)"; mv "$s/$id.jsonl" "$s/1111-2222.jsonl"
jq -n --arg r "$repo" '{format:1, session_id:"1111-2222", repo:$r, subpath:""}' >"$s/meta.json"
tar -czf "$tmp/h-badid.tar.gz" -C "$s" meta.json 1111-2222.jsonl
expect_reject "non-uuid transcript name" "$tmp/h-badid.tar.gz"

s="$(mkstage repoesc)"
jq -n --arg s "$id" '{format:1, session_id:$s, repo:"github.com/example-org/..", subpath:""}' >"$s/meta.json"
tar -czf "$tmp/h-repoesc.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
expect_reject "repo with .." "$tmp/h-repoesc.tar.gz"

s="$(mkstage subesc)"
jq -n --arg s "$id" --arg r "$repo" '{format:1, session_id:$s, repo:$r, subpath:"../../.."}' >"$s/meta.json"
tar -czf "$tmp/h-subesc.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
expect_reject "subpath with .." "$tmp/h-subesc.tar.gz"

exit "$fail"
