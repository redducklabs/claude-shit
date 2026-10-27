#!/usr/bin/env bash
# Claude Code PreToolUse hook, run for Bash calls matching `git commit *`.
# Scans the staged and unstaged changes to tracked files with gitleaks and blocks the
# call (exit 2) when it finds a secret, when gitleaks is missing, or when the scan fails.
# The hook runs before the whole Bash command, so a `git add` chained in the same
# command hasn't staged anything yet; such commands are blocked with a request to
# stage first and commit in a separate command.
# Limitation: it scans the repository in the session's working directory, so a
# `git -C <dir> commit` or `cd <dir> && git commit` into another repo is not covered.
set -u

input=$(cat)

# Run in the session's working directory. The JSON value is escaped, so collapse
# doubled backslashes in Windows paths (C:\\Users\\...).
cwd=$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | head -n 1 | sed 's/\\\\/\\/g')
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  cd "$cwd" || exit 2
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  # Not a repository: git itself will report the error.
  exit 0
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "Blocked: gitleaks is not installed, so this commit can't be scanned for secrets. Ask the user to install gitleaks (see the claude-shit README), then retry the commit." >&2
  exit 2
fi

# Leaks exit with 3 so they can be told apart from gitleaks' own errors (exit 1).
scan() {
  gitleaks git --pre-commit "$@" --redact --no-banner --no-color --verbose --exit-code 3 2>&1
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

if printf '%s' "$input" | grep -Eq 'git[[:space:]]+([^[:space:]"]+[[:space:]]+){0,3}(add|stage)([[:space:]]|"|\\)'; then
  echo "Blocked: this command stages files and commits in one step, so the new changes can't be scanned before the commit runs. Run the git add/stage in its own command first, then git commit separately." >&2
  exit 2
fi

out=$(scan --staged); rc=$?
report staged "$out" "$rc"

# Unstaged changes to tracked files: `git commit -a`, `--all`, or a pathspec commits them too.
out=$(scan); rc=$?
report unstaged "$out" "$rc"

exit 0
