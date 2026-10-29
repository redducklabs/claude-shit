#!/usr/bin/env bash
# Claude Code PreToolUse hook for Bash calls, configured with `if: "Bash(git commit *)"`.
# Scans the staged and unstaged changes to tracked files with gitleaks and blocks the
# call (exit 2) when it finds a secret, when gitleaks is missing, or when the scan fails.
# Claude Code also runs `if`-filtered hooks for commands it can't fully parse (variable
# expansions, for example), so the hook lets through commands that don't contain the
# word "commit" at all and scans everything else. Git aliases for commit (`git ci`)
# are not detected.
# The hook runs before the whole Bash command, so a `git add` chained in the same
# command hasn't staged anything yet; such commands are blocked with a request to
# stage first and commit in a separate command.
# When it blocks, it prints a short summary (at most 10 findings, under 4 KB) and keeps
# the full redacted gitleaks report in a per-run temp folder for the agent to inspect.
# Limitation: it scans the repository in the session's working directory, so a
# `git -C <dir> commit` or `cd <dir> && git commit` into another repo is not covered.
set -u

input=$(cat)

# json_field <name>: the first string value of that key in the hook input, still
# JSON-escaped (\" and \\ stay as they are).
json_field() {
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\(\([^\"\\\\]\|\\\\.\)*\)\".*/\1/p" | head -n 1
}

# Decode the JSON escapes that matter for matching: \n, \r, \t become spaces (a line
# continuation or tab can separate git from commit), \" and \\ become " and \.
cmd=$(json_field command | sed -e 's/\\[nrt]/ /g' -e 's/\\"/"/g' -e 's/\\\\/\\/g')
# Fail closed: scan whenever "commit" appears anywhere, rather than trying to recognize
# every way of writing a git commit (options, aliases aside, quoting, continuations).
case $cmd in
  *commit*) ;;
  *) exit 0 ;;
esac

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
    /opt/homebrew/bin/gitleaks \
    /home/linuxbrew/.linuxbrew/bin/gitleaks; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if ! gitleaks_bin=$(find_gitleaks); then
  case $(uname -s) in
    MINGW* | MSYS* | CYGWIN*) install='winget install Gitleaks.Gitleaks' ;;
    Darwin) install='brew install gitleaks' ;;
    *) install='mkdir -p ~/.local/bin && curl -sSfL https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz | tar -xz -C ~/.local/bin gitleaks' ;;
  esac
  echo "Blocked: gitleaks is not installed, so this commit can't be scanned for secrets. Ask the user to install it with: $install (no restart needed), then retry the commit." >&2
  exit 2
fi

# Hook output goes into the agent's context, so every message is capped: a merge can
# stage thousands of files, and an unbounded gitleaks log once overflowed a session in
# a single tool result.
max_findings=10
max_line=300
max_bytes=4000
show_path() { # a path the agent's file tools can open; Windows form under Git Bash
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}
block() { # block <message>: print at most max_bytes and exit 2
  printf '%s\n' "$1" | head -c "$max_bytes" >&2
  exit 2
}

# Leaks exit with 3 so they can be told apart from gitleaks' own errors (exit 1).
scan() { # scan <label> [gitleaks args]: report in $report_dir/<label>.json, log in <label>.log
  local label=$1
  shift
  "$gitleaks_bin" git --pre-commit "$@" --redact --no-banner --no-color --exit-code 3 \
    --report-format json --report-path "$report_dir/$label.json" >"$report_dir/$label.log" 2>&1
}

# findings <report>: one "File:Line  RuleID  Fingerprint" line per finding. Reads gitleaks'
# pretty-printed JSON line by line (one key per line, Fingerprint last), so no jq is needed.
findings() {
  awk '
    function val(s) { sub(/^[^:]*:[[:space:]]*"?/, "", s); sub(/"?,?[[:space:]]*$/, "", s); return s }
    /^[[:space:]]*"RuleID":/ { rule = val($0) }
    /^[[:space:]]*"StartLine":/ { line = val($0) }
    /^[[:space:]]*"File":/ { file = val($0) }
    /^[[:space:]]*"Fingerprint":/ { print file ":" line "  " rule "  " val($0) }
  ' "$1"
}

report() { # report <label> <gitleaks exit code>
  local label=$1 rc=$2 json=$report_dir/$1.json log=$report_dir/$1.log total more=""
  if [ "$rc" -eq 3 ]; then
    total=$(findings "$json" | wc -l | tr -d ' ')
    if [ "$total" -gt "$max_findings" ]; then
      more=$(printf '\n...and %s more' "$((total - max_findings))")
    fi
    block "$(printf 'Blocked: gitleaks found %s secret(s) in the %s changes. Remove them (and rotate any real credential) before committing.\nFull redacted report, to inspect (for example with jq) instead of re-running the scan: %s\n%s%s' \
      "$total" "$label" "$(show_path "$json")" "$(findings "$json" | head -n "$max_findings" | cut -c "1-$max_line")" "$more")"
  elif [ "$rc" -ne 0 ]; then
    block "$(printf 'Blocked: the gitleaks scan of the %s changes failed (exit %s), so the commit was not verified.\nFull output: %s\nLast lines:\n%s' \
      "$label" "$rc" "$(show_path "$log")" "$(tail -n "$max_findings" "$log" | cut -c "1-$max_line")")"
  fi
}

if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+([^[:space:]"]+[[:space:]]+){0,3}(add|stage)([[:space:]]|"|\\|$)'; then
  echo "Blocked: this command stages files and commits in one step, so the new changes can't be scanned before the commit runs. Run the git add/stage in its own command first, then git commit separately." >&2
  exit 2
fi

report_dir=$(mktemp -d "${TMPDIR:-/tmp}/secret-scan.XXXXXXXX") || {
  echo "Blocked: could not create a temp folder for the gitleaks report, so the commit was not verified." >&2
  exit 2
}
scan staged --staged; report staged $?

# Unstaged changes to tracked files: `git commit -a`, `--all`, or a pathspec commits them too.
scan unstaged; report unstaged $?

rm -rf "$report_dir"
exit 0
