#!/usr/bin/env bash
# Claude Code PreToolUse hook for Bash calls, configured with `if: "Bash(git commit *)"`.
# Scans the staged and unstaged changes to tracked files with gitleaks and blocks the
# call (exit 2) when it finds a secret, when gitleaks is missing, or when the scan fails.
# Claude Code also runs `if`-filtered hooks for commands it can't fully parse (variable
# expansions, for example), so the hook checks for `git ... commit` itself and lets
# anything else through.
# The hook runs before the whole Bash command, so a `git add` chained in the same
# command hasn't staged anything yet; such commands are blocked with a request to
# stage first and commit in a separate command.
# Limitation: it scans the repository in the session's working directory, so a
# `git -C <dir> commit` or `cd <dir> && git commit` into another repo is not covered.
set -u

input=$(cat)

# json_field <name>: the first string value of that key in the hook input, still
# JSON-escaped (\" and \\ stay as they are).
json_field() {
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\(\([^\"\\\\]\|\\\\.\)*\)\".*/\1/p" | head -n 1
}

cmd=$(json_field command)
if ! printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_.-])git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|\\|$)'; then
  exit 0
fi

# Run in the session's working directory. Collapse the doubled backslashes of
# escaped Windows paths (C:\\Users\\...).
cwd=$(json_field cwd | sed 's/\\\\/\\/g')
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  cd "$cwd" || exit 2
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  # Not a repository: git itself will report the error.
  exit 0
fi

# gitleaks may be installed but missing from PATH: a running Claude Code app keeps the
# PATH it started with, so a tool installed afterwards isn't visible until a restart.
find_gitleaks() {
  local candidate local_app_data=${LOCALAPPDATA:-}
  if command -v gitleaks >/dev/null 2>&1; then
    command -v gitleaks
    return 0
  fi
  if [ -n "$local_app_data" ] && command -v cygpath >/dev/null 2>&1; then
    local_app_data=$(cygpath -u "$local_app_data")
  fi
  for candidate in \
    "$local_app_data"/Microsoft/WinGet/Links/gitleaks.exe \
    "$local_app_data"/Microsoft/WinGet/Packages/Gitleaks.Gitleaks_*/gitleaks.exe \
    "$HOME"/.local/bin/gitleaks \
    /usr/local/bin/gitleaks \
    /home/linuxbrew/.linuxbrew/bin/gitleaks; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if ! gitleaks_bin=$(find_gitleaks); then
  echo "Blocked: gitleaks is not installed, so this commit can't be scanned for secrets. Ask the user to install gitleaks (see the claude-shit README), then retry the commit." >&2
  exit 2
fi

# Leaks exit with 3 so they can be told apart from gitleaks' own errors (exit 1).
scan() {
  "$gitleaks_bin" git --pre-commit "$@" --redact --no-banner --no-color --verbose --exit-code 3 2>&1
}

report() {
  local label=$1 out=$2 rc=$3
  if [ "$rc" -eq 3 ]; then
    printf 'Blocked: gitleaks found secrets in the %s changes. Remove them (and rotate any real credential) before committing.\n%s\n' "$label" "$out" >&2
    exit 2
  elif [ "$rc" -ne 0 ]; then
    printf 'Blocked: the gitleaks scan of the %s changes failed (exit %s), so the commit was not verified.\n%s\n' "$label" "$rc" "$out" >&2
    exit 2
  fi
}

if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+([^[:space:]"]+[[:space:]]+){0,3}(add|stage)([[:space:]]|"|\\|$)'; then
  echo "Blocked: this command stages files and commits in one step, so the new changes can't be scanned before the commit runs. Run the git add/stage in its own command first, then git commit separately." >&2
  exit 2
fi

out=$(scan --staged); rc=$?
report staged "$out" "$rc"

# Unstaged changes to tracked files: `git commit -a`, `--all`, or a pathspec commits them too.
out=$(scan); rc=$?
report unstaged "$out" "$rc"

exit 0
