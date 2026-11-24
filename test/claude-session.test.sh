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
# Loose on purpose: the mode assertions below only mean something if the
# script's own umask is what tightens the files.
umask 022
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

# TMPDIR is pinned so the script's staging dirs (and anything an archive
# escapes to) land somewhere the tests can inspect.
mkdir -p "$tmp/td"
run_a() { TMPDIR="$tmp/td" PATH="$stubbin:$PATH" CLAUDE_CONFIG_DIR="$cfg_a" GHQ_STUB_ROOT="$root_a" "$src" "$@"; }
run_b() { TMPDIR="$tmp/td" PATH="$stubbin:$PATH" CLAUDE_CONFIG_DIR="$cfg_b" GHQ_STUB_ROOT="$root_b" "$src" "$@"; }
# No staging dir may outlive a run, whether it succeeded or failed.
td_clean() { # <label>
  if [ -z "$(ls -A "$tmp/td")" ]; then ok "staging dir removed: $1"
  else ng "staging dir left behind ($1): $(ls -A "$tmp/td")"; rm -rf "${tmp:?}/td"; mkdir -p "$tmp/td"; fi
}

# Expected projects/ dir name, written independently of the script.
enc() { local p="$1"; p="${p//\//-}"; printf '%s\n' "${p//./-}"; }

# make_session <cfg> <cwd> <id>: a transcript whose first line has no string
# cwd, so the script must skip to the first real one.
make_session() {
  local d
  d="$1/projects/$(enc "$2")"
  mkdir -p "$d"
  {
    printf '{"type":"summary","cwd":null,"sessionId":"%s"}\n' "$3"
    printf '{"type":"user","cwd":"%s","sessionId":"%s","message":"hello"}\n' "$2" "$3"
    printf '{"type":"assistant","cwd":"%s","sessionId":"%s","message":"hi"}\n' "$2" "$3"
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
td_clean "after export"
if [ "$(stat -c %a "$arch")" = 600 ]; then ok "the archive is owner-only (umask 077)"
else ng "archive mode $(stat -c %a "$arch")"; fi

out="$(run_b import "$arch" 2>/dev/null)"; rc=$?
dest="$cfg_b/projects/$(enc "$root_b/$repo")"
if [ "$rc" -eq 0 ] && cmp -s "$src_dir/$id.jsonl" "$dest/$id.jsonl"; then
  ok "import places a byte-identical jsonl under the destination cwd's <enc>"
else ng "round trip rc=$rc dest=$dest; ls: $(ls -R "$cfg_b" 2>&1)"; fi
td_clean "after import"
if [ -z "$(find "$dest/$id" "$dest/$id.jsonl" -perm /077)" ]; then
  ok "imported files carry no group/other bits"
else ng "imported modes: $(find "$dest/$id" "$dest/$id.jsonl" -perm /077)"; fi
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

# --- cwd selection ---------------------------------------------------------
# A session that moved records several cwds. Only the one whose encoding names
# the projects/ dir the transcript sits in is the session's place.
make_raw() { # <cfg> <enc-source cwd> <id> <cwd>...: one line per cwd, in order
  local d i="$3" c
  d="$1/projects/$(enc "$2")"
  shift 3
  mkdir -p "$d"
  : >"$d/$i.jsonl"
  for c in "$@"; do printf '{"type":"user","cwd":"%s"}\n' "$c" >>"$d/$i.jsonl"; done
}
mid=77777777-8888-9999-aaaa-bbbbbbbbbbbb
make_raw "$cfg_a" "$root_a/$repo" "$mid" "$root_a/github.com/example-org/moved-away" "$root_a/$repo"
run_a export "$mid" -o "$tmp/mv.tar.gz" >/dev/null 2>&1; rc=$?
mv_repo="$(tar -xzOf "$tmp/mv.tar.gz" meta.json 2>/dev/null | jq -r .repo)"
if [ "$rc" -eq 0 ] && [ "$mv_repo" = "$repo" ]; then
  ok "the cwd matching the projects/ dir is used, not the first one"
else ng "moved session rc=$rc repo=$mv_repo"; fi
nid=88888888-9999-aaaa-bbbb-cccccccccccc
make_raw "$cfg_a" "$root_a/$repo" "$nid" "$root_a/github.com/example-org/moved-away"
err="$(run_a export "$nid" -o "$tmp/nm.tar.gz" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/nm.tar.gz" ] && grep -q 'no cwd' <<<"$err"; then
  ok "a transcript with no cwd matching its projects/ dir is refused"
else ng "no matching cwd rc=$rc err=$err"; fi
td_clean "after failed exports"

# --- other export checks ---------------------------------------------------
lid=99999999-aaaa-bbbb-cccc-dddddddddddd
ldir="$(make_session "$cfg_a" "$root_a/$repo" "$lid")"
mkdir -p "$ldir/$lid"; ln -s /etc/passwd "$ldir/$lid/l.txt"
run_a export "$lid" -o "$tmp/l.tar.gz" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/l.tar.gz" ]; then ok "a symlink in the sidecar makes export fail"
else ng "sidecar symlink rc=$rc"; fi
rm -f "$ldir/$lid/l.txt"; printf 'x\n' >"$ldir/$lid/.hidden"
run_a export "$lid" -o "$tmp/hd.tar.gz" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/hd.tar.gz" ]; then ok "a name import would refuse in the sidecar makes export fail"
else ng "sidecar hidden file rc=$rc"; fi
rm -rf "${ldir:?}/$lid"
td_clean "after sidecar refusals"

ln -s "$tmp/dangling-target" "$tmp/dangling.tar.gz"
run_a export "$lid" -o "$tmp/dangling.tar.gz" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/dangling-target" ]; then ok "-o naming a dangling symlink is refused, nothing written through it"
else ng "dangling -o rc=$rc"; fi

# --- CLI misuse ------------------------------------------------------------
out="$(run_a 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then ok "no arguments: usage on stderr, non-zero"
else ng "no args rc=$rc stdout=$out"; fi
out="$(run_a --help 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Usage:' <<<"$out"; then ok "--help prints usage on stdout"
else ng "help rc=$rc"; fi
err="$(run_a bogus 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'unknown subcommand' <<<"$err"; then ok "unknown subcommand is refused"
else ng "unknown subcommand rc=$rc"; fi
run_a export >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "export without an id is refused"; else ng "export no id rc=$rc"; fi
err="$(run_a export "$id" -o 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q -- '-o needs' <<<"$err"; then ok "-o without a value is refused"
else ng "-o no value rc=$rc err=$err"; fi
err="$(run_a export "$id" "$wid" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'more than one' <<<"$err"; then ok "two session ids are refused"
else ng "two ids rc=$rc err=$err"; fi

# --- hostile archives -----------------------------------------------------
# Each is built by hand from a clean stage, then altered one way. The import
# must fail and place nothing. Extraction happens in a dir directly under
# $tmp/td, so a member escaping with `..` would land in $tmp/td/escaped;
# the dotdot case also asserts the script's own member check is what refused
# it (GNU tar would refuse `..` at extraction too).
mkstage() {
  local s="$tmp/stage.$1"
  rm -rf "$s"; mkdir -p "$s/$id/tool-results"
  cp "$src_dir/$id.jsonl" "$s/"
  printf 'x\n' >"$s/$id/tool-results/t.txt"
  jq -n --arg s "$id" --arg r "$repo" '{format:1, session_id:$s, repo:$r, subpath:""}' >"$s/meta.json"
  printf '%s\n' "$s"
}
expect_reject() { # <label> <archive> [<stderr pattern>]
  local err rc
  reset_b
  err="$(run_b import "$2" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$(find "$cfg_b" -name "$id*" 2>/dev/null)" ] \
     && [ ! -e "$tmp/td/escaped" ] && { [ -z "${3:-}" ] || grep -q -- "$3" <<<"$err"; }; then
    ok "hostile archive rejected: $1"
  else ng "hostile archive accepted ($1) rc=$rc err=$err"; fi
  rm -f "$tmp/td/escaped"
  td_clean "after rejecting: $1"
}

# The clean stage itself must import, or every rejection below proves nothing.
s="$(mkstage clean)"; tar -czf "$tmp/h-clean.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
reset_b
if run_b import "$tmp/h-clean.tar.gz" >/dev/null 2>&1 && [ -f "$dest/$id.jsonl" ]; then
  ok "control: the hand-built clean archive imports"
else ng "control: hand-built clean archive did not import"; fi

s="$(mkstage dotdot)"; printf 'pwn\n' >"$s/escaped"
tar -czf "$tmp/h-dotdot.tar.gz" -P -C "$s" --transform "s,^escaped\$,$id/../../escaped," meta.json "$id.jsonl" "$id" escaped
expect_reject "member with .." "$tmp/h-dotdot.tar.gz" "disallowed component"

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

# The dirs exist, so only the shape checks (not a missing destination) can refuse these.
mkdir -p "$root_b/$repo/extra" "$root_b/$repo/5" "$root_b/$repo/null"
s="$(mkstage repo4)"
jq -n --arg s "$id" '{format:1, session_id:$s, repo:"github.com/example-org/example-repo/extra", subpath:""}' >"$s/meta.json"
tar -czf "$tmp/h-repo4.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
expect_reject "repo with four components" "$tmp/h-repo4.tar.gz"

# meta.json shape. Each subpath below would resolve to an existing dir if it
# were silently normalised, so only the type/shape checks can refuse them.
mkdir -p "$root_b/$repo/foo"
meta_case() { # <label> <jq program producing meta.json>
  s="$(mkstage "meta-$1")"
  jq -n --arg s "$id" --arg r "$repo" "$2" >"$s/meta.json"
  tar -czf "$tmp/h-meta-$1.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
  expect_reject "meta.json: $1" "$tmp/h-meta-$1.tar.gz"
}
meta_case format-string '{format:"1", session_id:$s, repo:$r, subpath:""}'
meta_case subpath-missing '{format:1, session_id:$s, repo:$r}'
meta_case subpath-number '{format:1, session_id:$s, repo:$r, subpath:5}'
meta_case not-an-object '[1]'
meta_case subpath-trailing-slash '{format:1, session_id:$s, repo:$r, subpath:"foo/"}'
meta_case subpath-double-slash '{format:1, session_id:$s, repo:$r, subpath:"foo//bar"}'
meta_case subpath-newline '{format:1, session_id:$s, repo:$r, subpath:"foo\nbar"}'

s="$(mkstage sidefile)"; rm -rf "${s:?}/$id"; printf 'x\n' >"$s/$id"
tar -czf "$tmp/h-sidefile.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
expect_reject "<id> member is a regular file" "$tmp/h-sidefile.tar.gz"

# Hostile permissions must neither wedge the import nor leave a stage behind.
s="$(mkstage perms)"
tar -czf "$tmp/h-perms.tar.gz" --mode='a=' -C "$s" meta.json "$id.jsonl" "$id"
reset_b
run_b import "$tmp/h-perms.tar.gz" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$src_dir/$id.jsonl" "$dest/$id.jsonl" && [ -f "$dest/$id/tool-results/t.txt" ] \
   && [ -z "$(find "$dest" ! -perm -u+rw -type f)" ] && [ -z "$(find "$dest" -type d ! -perm -u+rwx)" ]; then
  ok "members archived as mode 000 import cleanly into usable files"
else ng "mode-000 archive rc=$rc; ls: $(ls -lR "$dest" 2>&1)"; fi
td_clean "after mode-000 import"

# A sidecar left at the destination (no transcript) is still a collision, and
# nothing may be added next to it.
s="$(mkstage collide)"; tar -czf "$tmp/h-collide.tar.gz" -C "$s" meta.json "$id.jsonl" "$id"
reset_b; mkdir -p "$dest/$id"
err="$(run_b import "$tmp/h-collide.tar.gz" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'already exists' <<<"$err" && [ ! -e "$dest/$id/$id" ] \
   && [ ! -e "$dest/$id.jsonl" ] && [ -z "$(ls -A "$dest/$id")" ]; then
  ok "a leftover <id>/ at the destination is a collision, nothing placed"
else ng "sidecar-only collision rc=$rc err=$err"; fi
td_clean "after sidecar-only collision"
reset_b

# --- --repo: import into a repo cloned under another name ------------------
# $root_b/$repo exists too, so an import that ignored --repo would succeed
# there instead of failing.
rrepo=github.com/example-org/renamed-repo
mkdir -p "$root_b/$rrepo"
rdest="$cfg_b/projects/$(enc "$root_b/$rrepo")"
reset_b
out="$(run_b import --repo "$rrepo" "$arch" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$src_dir/$id.jsonl" "$rdest/$id.jsonl" && [ ! -e "$dest/$id.jsonl" ] \
   && diff -r "$src_dir/$id" "$rdest/$id" >/dev/null 2>&1; then
  ok "--repo places a byte-identical jsonl under the overriding repo's <enc>"
else ng "--repo round trip rc=$rc; ls: $(ls -R "$cfg_b" 2>&1)"; fi
if [ "$out" = "cd $root_b/$rrepo && claude --resume $id" ]; then
  ok "--repo: the resume command names the overriding repo"
else ng "--repo resume hint: $out"; fi
td_clean "after --repo import"

# The archive's subpath is kept under the overriding repo.
mkdir -p "$root_b/$rrepo/.worktrees/feature-foo"
reset_b
run_b import --repo "$rrepo" "$tmp/w.tar.gz" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$cfg_b/projects/$(enc "$root_b/$rrepo/.worktrees/feature-foo")/$wid.jsonl" ] \
   && [ ! -e "$rdest/$wid.jsonl" ]; then
  ok "--repo keeps meta.json's subpath"
else ng "--repo with subpath rc=$rc; ls: $(ls -R "$cfg_b/projects" 2>&1)"; fi

# Bad values. Each would resolve to an existing dir if it went unchecked, so
# only the --repo checks can refuse them (and the message must say so).
mkdir -p "$root_b/$rrepo/extra"
bad_repo() { # <label> <stderr pattern> <import args>...
  local label="$1" pat="$2" err rc
  shift 2
  reset_b
  err="$(run_b import "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$(find "$cfg_b" -name "$id*" 2>/dev/null)" ] && grep -q -- "$pat" <<<"$err"; then
    ok "--repo rejected: $label"
  else ng "--repo accepted ($label) rc=$rc err=$err"; fi
  td_clean "after --repo rejection: $label"
}
bad_repo "two components" "--repo must have at least 3" --repo github.com/example-org "$arch"
bad_repo "four components" "--repo must be" --repo "$rrepo/extra" "$arch"
bad_repo "with .." "bad --repo component" --repo github.com/example-org/.. "$arch"
bad_repo "absolute" "bad --repo (leading" --repo "/$rrepo" "$arch"
bad_repo "no value" "--repo needs" "$arch" --repo
bad_repo "unknown option" "unknown option" --rep "$rrepo" "$arch"

# meta.json's repo is still checked when --repo overrides it.
bad_repo "meta.json repo with .. under a valid --repo" "bad repo component" --repo "$rrepo" "$tmp/h-repoesc.tar.gz"

# A missing destination names the repo actually used.
reset_b
err="$(run_b import --repo github.com/example-org/absent-repo "$arch" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'ghq get github.com/example-org/absent-repo)' <<<"$err" \
   && ! grep -q "$repo" <<<"$err" && [ ! -d "$cfg_b/projects" ]; then
  ok "--repo: a missing destination names the overriding repo"
else ng "--repo missing dest rc=$rc err=$err"; fi
td_clean "after --repo missing destination"
reset_b

exit "$fail"
