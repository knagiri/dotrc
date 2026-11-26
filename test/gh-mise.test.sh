#!/usr/bin/env bash
# Tests for gh_mise_main_root (bin/lib/gh-mise.sh): it resolves the MAIN working
# tree from anywhere in a checkout, so `gh_mise_use "$(gh_mise_main_root)"`
# keeps a linked worktree's mise config out of gh's environment. The wrapper
# plumbing of gh_mise itself is covered by test/gh-wrappers.test.sh.
# No test framework; run with bash.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
lib="$here/../bin/lib/gh-mise.sh"
fail=0

tmp="$(mktemp -d)"
trap 'sandbox_cleanup; rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"

# The dotrc layout: linked worktrees live inside the main checkout, under
# .worktrees/<name>. A worktree's own config must not be read at all, because
# any branch can change its tracked mise.toml. The nesting is what makes that
# matter: mise walking up from the worktree reads both the worktree's config and
# the main checkout's, and the worktree's (nearer) one wins.
main="$tmp/main"
git init -q -b main "$main"
git -C "$main" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
mkdir -p "$main/sub"
git -C "$main" worktree add -q -b wt "$main/.worktrees/wt" 2>/dev/null
wt="$main/.worktrees/wt"
mkdir -p "$wt/sub"
# A linked worktree outside the main checkout (git allows any path).
git -C "$main" worktree add -q -b el "$tmp/elsewhere" 2>/dev/null
elsewhere="$tmp/elsewhere"

# Runs gh_mise_main_root in a fresh shell from <cwd>; prints its output, keeps its rc.
main_root() {  # main_root <lib> <cwd> [<dir arg>]
  # shellcheck disable=SC1090  # the lib or a mutant of it
  ( cd "$2" && . "$1" && gh_mise_main_root "${@:3}" )
}

check() {  # check <desc> <expected output> <lib> <cwd> [<dir arg>]
  local out rc
  out="$(main_root "${@:3}")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$2" ]; then echo "ok: $1"
  else echo "FAIL: $1 (rc=$rc out=$out)"; fail=1; fi
}
check "main root from the main checkout" "$main" "$lib" "$main"
check "main root from a subdirectory of the main checkout" "$main" "$lib" "$main/sub"
check "main root from a linked worktree" "$main" "$lib" "$wt"
check "main root from a subdirectory of a linked worktree" "$main" "$lib" "$wt/sub"
check "main root from a linked worktree outside the main checkout" "$main" "$lib" "$elsewhere"
check "main root of an explicit <dir> argument" "$main" "$lib" "$tmp" "$wt/sub"

refuses() {  # refuses <desc> <lib> <cwd> [<dir arg>]  (the contract is rc 1, no output)
  local out rc
  out="$(main_root "${@:2}" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$out" ]; then echo "ok: $1"
  else echo "FAIL: $1 (rc=$rc out=$out)"; fail=1; fi
}
mkdir -p "$tmp/plain"
refuses "outside a checkout it fails with no output" "$lib" "$tmp/plain"

# A submodule's common dir is <super>/.git/modules/<name>, whose parent is no
# working tree; resolving it to a directory there would be wrong.
sub_src="$tmp/subsrc"
git init -q -b main "$sub_src"
git -C "$sub_src" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$main" -c protocol.file.allow=always submodule add -q "$sub_src" mod 2>/dev/null
if [ -d "$main/mod" ] && [ -f "$main/mod/.git" ]; then
  refuses "inside a submodule it fails rather than naming .git/modules" "$lib" "$main/mod"
else echo "FAIL: could not set up the submodule fixture"; fail=1; fi

# Bare repos: a bare repo's common dir is never `<toplevel>/.git`, so none of
# these may resolve, however the bare repo and its linked worktrees are placed.
git clone -q --bare "$main" "$main/sub/bare.git"          # inside a checkout, below its toplevel
git clone -q --bare "$main" "$main/bare.git"              # directly under a checkout's toplevel
git clone -q --bare "$main" "$tmp/outbare.git"            # outside any checkout
git -C "$main/bare.git" worktree add -q -b tb "$tmp/tb-wt" 2>/dev/null
git -C "$tmp/outbare.git" worktree add -q -b ob "$tmp/ob-wt" 2>/dev/null
refuses "a bare repo nested below a checkout's toplevel fails" "$lib" "$main/sub/bare.git"
refuses "a bare repo directly under a checkout's toplevel fails (not the outer checkout)" "$lib" "$main/bare.git"
refuses "a linked worktree of a bare repo under a checkout's toplevel fails" "$lib" "$tmp/tb-wt"
refuses "a bare repo outside any checkout fails" "$lib" "$tmp/outbare.git"
refuses "a linked worktree of a bare repo outside any checkout fails" "$lib" "$tmp/ob-wt"

# --separate-git-dir: the common dir is not `<toplevel>/.git`, so it fails too.
git init -q -b main --separate-git-dir "$tmp/sep.gitdir" "$tmp/sepwork"
refuses "a --separate-git-dir checkout fails" "$lib" "$tmp/sepwork"

# Discrimination (evidence-over-guesswork §4). The lib's guards are new, so
# each is mutated on its own. mutant() must run in the caller's shell (not a
# command substitution) so a no-op mutant sets the caller's fail; it writes to
# $tmp/mutant-<name>.sh, and a sed that matched nothing is detected and FAILs.
mutant() {  # mutant <name> <sed expression>
  local m="$tmp/mutant-$1.sh"
  sed "$2" "$lib" >"$m"
  if cmp -s "$lib" "$m"; then
    echo "FAIL: mutant '$1' is identical to gh-mise.sh; the check is a no-op" >&2; fail=1
  fi
}
# Anchoring at the worktree's own toplevel instead of the common dir's parent.
mutant toplevel '/^gh_mise_main_root()/,/^}/s#^  common=.*#  common="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)/.git" || return 1#'
m_toplevel="$tmp/mutant-toplevel.sh"
out="$(main_root "$m_toplevel" "$wt/sub")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$wt" ]; then
  echo "ok: mutant 'toplevel' resolves a worktree to itself (the linked-worktree case is discriminating)"
else echo "FAIL: mutant 'toplevel' rc=$rc out=$out (want rc 0, out=$wt)"; fail=1; fi
# The `top = main` check is not mutated: given the basename check and a
# successful show-toplevel it is redundant for every fixture tried (a `.git`
# directory makes its parent a toplevel by git's own discovery), so removing it
# changes nothing observable. It stays as a defensive check.
# Dropping the `basename common = .git` check.
mutant nobasename '/^gh_mise_main_root()/,/^}/s#\[ "\$(basename "\$common")" = \.git \] || return 1#:#'
for f in "$main/bare.git" "$tmp/tb-wt"; do
  out="$(main_root "$tmp/mutant-nobasename.sh" "$f" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$main" ]; then
    echo "ok: mutant 'nobasename' names the outer checkout for ${f#"$tmp"/} (the basename check is discriminating)"
  else echo "FAIL: mutant 'nobasename' for $f rc=$rc out=$out"; fail=1; fi
done

# gh_mise_use rejects an empty directory.
use_rc() {  # use_rc <lib> -> rc of `gh_mise_use ""`
  # shellcheck disable=SC1090
  ( . "$1" && gh_mise_use "" ) >/dev/null 2>&1
}
use_rc "$lib"; rc=$?
[ "$rc" -eq 1 ] && echo "ok: gh_mise_use rejects an empty directory" \
  || { echo "FAIL: gh_mise_use \"\" rc=$rc"; fail=1; }
mutant useguard 's#^  if \[ -z "\${1:-}" \]; then#  if false; then#'
use_rc "$tmp/mutant-useguard.sh"; rc=$?
[ "$rc" -eq 0 ] && echo "ok: mutant 'useguard' accepts an empty directory (the guard is discriminating)" \
  || { echo "FAIL: mutant 'useguard' rc=$rc"; fail=1; }
# Both guards off restores the old lazy fallback to the cwd's toplevel.
mutant failopen 's#^  if \[ -z "\${1:-}" \]; then#  if false; then#;s#^  if \[ -z "\$gh_mise_dir" \]; then#  gh_mise_dir="$(gh_mise_repo_root)"; if false; then#'

# With the real mise: a GH_TOKEN planted in a tracked mise.toml of a linked
# worktree reaches gh when gh_mise is anchored at that worktree
# (gh_mise_repo_root) and does not when anchored at gh_mise_main_root. Two
# main-checkout variants cover both token sources: with mise.gh.local.toml gh
# gets its PAT; without it gh gets no GH_TOKEN and so falls to hosts.yml.
# The gh stub records `ran:<GH_TOKEN>`: a missing record means gh never ran,
# which is told apart from "ran with no token" (`ran:`).
# Hermetic as in gh-wrappers.test.sh: trust via MISE_TRUSTED_CONFIG_PATHS, no
# global config, the config walk stops at $tmp, ambient MISE_ENV/GH_* removed.
realmise="$(command -v mise 2>/dev/null || true)"
if [ -z "$realmise" ]; then
  echo "skip: no real mise on PATH; the token-resolution cases need it"
else
  stub="$tmp/stub"; mkdir -p "$stub" "$tmp/cfg"
  printf '#!/usr/bin/env bash\nprintf "ran:%%s\\n" "${GH_TOKEN:-}" >"$GH_TOKEN_FILE"\n' >"$stub/gh"
  chmod +x "$stub/gh"
  printf '[env]\nGH_TOKEN = "tok-from-worktree"\n' >"$wt/mise.toml"
  printf '[env]\nGH_TOKEN = "tok-from-bare-wt"\n' >"$tmp/ob-wt/mise.toml"
  # token_via <lib> <safe|unsafe> <resolver> <cwd> -> what gh recorded, "" if it
  # never ran. safe = the documented form (stop on a failed resolve); unsafe =
  # `gh_mise_use "$(...)"`, which ignores the resolver's rc.
  token_via() {
    local form
    if [ "$2" = safe ]; then form='root="$("$2")" || exit 97; gh_mise_use "$root" && gh_mise pr view 1'
    else form='gh_mise_use "$("$2")"; gh_mise pr view 1'; fi
    rm -f "$tmp/token"
    ( cd "$4" && env -u MISE_ENV -u GH_TOKEN -u GITHUB_TOKEN \
        MISE_TRUSTED_CONFIG_PATHS="$tmp" MISE_CEILING_PATHS="$tmp" \
        MISE_GLOBAL_CONFIG_FILE="$tmp/none.toml" MISE_CONFIG_DIR="$tmp/cfg" \
        GH_TOKEN_FILE="$tmp/token" PATH="$stub:$PATH" \
        bash -c '. "$1" && '"$form" _ "$1" "$3" ) >/dev/null 2>"$tmp/stderr"
    cat "$tmp/token" 2>/dev/null || true
  }
  tcheck() {  # tcheck <desc> <expected record> <lib> <form> <resolver> <cwd>
    local t; t="$(token_via "$3" "$4" "$5" "$6")"
    if [ "$t" = "$2" ]; then echo "ok: $1"
    else echo "FAIL: $1 (record='$t', want '$2'; stderr: $(head -c 300 "$tmp/stderr"))"; fail=1; fi
  }

  # Control: the existing worktree-anchored resolution does pick up the plant,
  # so its absence below is not just a config mise never read.
  tcheck "control: anchored at the worktree, mise hands gh the worktree's GH_TOKEN" \
    ran:tok-from-worktree "$lib" safe gh_mise_repo_root "$wt/sub"

  printf '[env]\nGH_TOKEN = "tok-personal"\n' >"$main/mise.gh.local.toml"
  tcheck "anchored at the main root, gh gets the main checkout's personal PAT, not the worktree's" \
    ran:tok-personal "$lib" safe gh_mise_main_root "$wt/sub"

  rm "$main/mise.gh.local.toml"
  tcheck "anchored at the main root with no mise.gh.local.toml, gh runs with no GH_TOKEN (hosts.yml)" \
    ran: "$lib" safe gh_mise_main_root "$wt/sub"

  tcheck "mutant 'toplevel' lets the worktree's GH_TOKEN through (the cases above are discriminating)" \
    ran:tok-from-worktree "$tmp/mutant-toplevel.sh" safe gh_mise_main_root "$wt/sub"

  # A refused fixture must not reach gh at all, in the documented form and in
  # the careless `gh_mise_use "$(...)"` form (gh_mise_use / gh_mise refuse).
  for form in safe unsafe; do
    tcheck "bare repo's linked worktree ($form form): gh never runs, the worktree's GH_TOKEN does not arrive" \
      "" "$lib" "$form" gh_mise_main_root "$tmp/ob-wt"
    tcheck "submodule ($form form): gh never runs" "" "$lib" "$form" gh_mise_main_root "$main/mod"
  done
  tcheck "mutant 'failopen' falls back to the worktree's config in the unsafe form (the guards are discriminating)" \
    ran:tok-from-bare-wt "$tmp/mutant-failopen.sh" unsafe gh_mise_main_root "$tmp/ob-wt"
fi

exit "$fail"
