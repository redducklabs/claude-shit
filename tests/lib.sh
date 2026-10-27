# shellcheck shell=bash
# Shared helpers for the bash test scripts.
FAILS=0
PASSES=0

pass() { PASSES=$((PASSES + 1)); printf 'ok    %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; return 0; }

assert_eq() { # assert_eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
assert_contains() { # assert_contains <name> <needle> <haystack>
  case $3 in *"$2"*) pass "$1" ;; *) fail "$1" "missing [$2] in: $3" ;; esac
}
assert_not_contains() {
  case $3 in *"$2"*) fail "$1" "unexpected [$2] in: $3" ;; *) pass "$1" ;; esac
}
assert_file() { if [ -f "$2" ]; then pass "$1"; else fail "$1" "no file $2"; fi; }
assert_no_file() { if [ -e "$2" ]; then fail "$1" "unexpected file $2"; else pass "$1"; fi; }

finish() {
  printf '\n%s passed, %s failed\n' "$PASSES" "$FAILS"
  [ "$FAILS" -eq 0 ]
}

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Copy the parts of the repo the sync scripts read, so tests can mutate them.
make_repo_copy() { # make_repo_copy <dest>
  mkdir -p "$1"
  (cd "$REPO_ROOT" && cp -r claude_md rules commands hooks agents settings install "$1/")
}
