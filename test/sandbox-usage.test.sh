#!/usr/bin/env bash
# Static check that every test/*.test.sh opts into the sandbox helper:
#   - sources test/lib/sandbox.sh and calls sandbox_assert on the next line
#   - any `trap ... EXIT` it sets also calls sandbox_cleanup (a later EXIT trap
#     replaces the one the helper installed)
# Then runs the same check on generated bad fixtures to show it discriminates.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib/sandbox.sh
. "$here/lib/sandbox.sh"
sandbox_assert
fail=0

# check_file <path>: prints problems, returns 1 if any.
check_file() {
  local f="$1" rc=0 n
  n="$(grep -nF '. "$here/lib/sandbox.sh"' "$f" | head -1 | cut -d: -f1)"
  if [ -z "$n" ]; then
    echo "  no sandbox.sh source line"; return 1
  fi
  if [ "$(sed -n "$((n + 1))p" "$f")" != "sandbox_assert" ]; then
    echo "  sandbox_assert does not directly follow the source line"; rc=1
  fi
  if grep -E '^[[:space:]]*trap .* EXIT' "$f" | grep -vq 'sandbox_cleanup'; then
    echo "  an EXIT trap does not call sandbox_cleanup"; rc=1
  fi
  return "$rc"
}

for f in "$here"/*.test.sh; do
  if out="$(check_file "$f")"; then
    echo "ok: $(basename "$f")"
  else
    echo "FAIL: $(basename "$f")"; echo "$out"; fail=1
  fi
done

# Discrimination: each broken fixture must be rejected.
fx="$sandbox_dir/fx"; mkdir -p "$fx"
good='. "$here/lib/sandbox.sh"
sandbox_assert
trap '"'"'sandbox_cleanup; rm -rf x'"'"' EXIT'
printf '%s\n' "$good" >"$fx/good.sh"
printf '%s\n' 'echo hi' >"$fx/nosource.sh"
printf '%s\n' '. "$here/lib/sandbox.sh"' 'echo hi' >"$fx/noassert.sh"
printf '%s\n' '. "$here/lib/sandbox.sh"' 'sandbox_assert' "trap 'rm -rf x' EXIT" >"$fx/nocleanup.sh"
check_file "$fx/good.sh" >/dev/null \
  || { echo "FAIL: control fixture rejected"; fail=1; }
for bad in nosource noassert nocleanup; do
  if check_file "$fx/$bad.sh" >/dev/null; then
    echo "FAIL: $bad fixture was accepted"; fail=1
  fi
done

[ "$fail" = 0 ] && echo "all passed"
exit "$fail"
