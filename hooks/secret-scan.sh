#!/usr/bin/env bash
# Claude Code PreToolUse hook for Bash and PowerShell calls, configured with
# `if: "Bash(git commit *)"` and `if: "PowerShell(git commit *)"`. Both tools pass the
# command in tool_input.command, so the same checks apply to either.
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
# During a merge, staged findings on lines that are unchanged from every merged-in
# parent are skipped: that content is already committed upstream. Unstaged changes are
# scanned only when the command can commit them (-a, --all, -i, -o, -p, a pathspec, or
# an argument the hook can't read, such as a variable).
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
# gitleaks treats any stderr from its git diff as an error, logs it, and reports no leaks
# with exit 0, so git's "LF will be replaced by CRLF" warning (core.autocrlf on Windows)
# would silently skip the scan. core.safecrlf=false turns that warning off for gitleaks'
# git calls, and any ERR line in the log still counts as a failed scan.
scan() { # scan <label> [gitleaks args]: report in $report_dir/<label>.json, log in <label>.log
  local label=$1 n=${GIT_CONFIG_COUNT:-0} rc
  shift
  env GIT_CONFIG_COUNT=$((n + 1)) "GIT_CONFIG_KEY_$n=core.safecrlf" "GIT_CONFIG_VALUE_$n=false" \
    "$gitleaks_bin" git --pre-commit "$@" --redact --no-banner --no-color --exit-code 3 \
    --report-format json --report-path "$report_dir/$label.json" >"$report_dir/$label.log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q ' ERR ' "$report_dir/$label.log"; then
    return 1
  fi
  return "$rc"
}

# findings <report>: one "File<TAB>StartLine<TAB>EndLine<TAB>RuleID<TAB>Fingerprint" line
# per finding. Reads gitleaks' pretty-printed JSON line by line (one key per line,
# Fingerprint last), so no jq is needed.
findings() {
  awk '
    function val(s) { sub(/^[^:]*:[[:space:]]*"?/, "", s); sub(/"?,?[[:space:]]*$/, "", s); return s }
    /^[[:space:]]*"RuleID":/ { rule = val($0) }
    /^[[:space:]]*"StartLine":/ { start = val($0) }
    /^[[:space:]]*"EndLine":/ { end = val($0) }
    /^[[:space:]]*"File":/ { file = val($0) }
    /^[[:space:]]*"Fingerprint":/ { print file "\t" start "\t" end "\t" rule "\t" val($0) }
  ' "$1"
}

# new_in_merge <findings>: during a merge, keep only findings with at least one line that
# is new relative to every merged-in parent (MERGE_HEAD). Lines that match a parent are
# already committed upstream. Fails closed: every finding is kept unless each parent is
# already on a remote-tracking branch (so MERGE_HEAD can't point at an unpushed commit
# made to hide a secret) and every diff succeeds; a finding is also kept when its path
# has characters that git or JSON escape, or when its file differs from a parent but no
# hunk for it could be read.
new_in_merge() {
  local list=$1 diff=$report_dir/merge.diff head
  if ! (
    while read -r head; do
      [ -n "$(git for-each-ref --contains "$head" --count=1 --format=x refs/remotes)" ] || exit 1
      echo "@@NAMES"
      git -c core.quotePath=false diff --cached --no-renames --name-only -z "$head" | tr '\0' '\n'
      [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
      echo "@@DIFF"
      git -c core.quotePath=false diff --cached --no-color --no-ext-diff --no-renames --text -U0 "$head" || exit 1
    done <"$(git rev-parse --git-path MERGE_HEAD)"
  ) >"$diff"; then
    cat "$list"
    return 0
  fi
  awk -F '\t' -v diff="$diff" '
    FILENAME == diff {
      if ($0 == "@@NAMES") { parents++; section = "names"; file = ""; next }
      if ($0 == "@@DIFF") { section = "diff"; next }
      if (section == "names") { changed[parents, $0] = 1; next }
      # Inside a hunk, count its lines: content such as "++ x" shows up as "+++ x".
      if (remaining > 0) { if (substr($0, 1, 1) != "\\") remaining--; next }
      if (substr($0, 1, 11) == "diff --git ") { file = ""; next }
      if (substr($0, 1, 4) == "+++ ") {
        file = substr($0, 5); sub(/\t$/, "", file)
        file = (file ~ /^b\//) ? substr(file, 3) : ""
        next
      }
      if ($0 ~ /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/) {
        h = $0; sub(/^@@ -/, "", h); sub(/ @@.*/, "", h)
        split(h, side, " \\+")
        n = split(side[1], part, ","); remaining = (n > 1) ? part[2] + 0 : 1
        n = split(side[2], part, ","); first = part[1] + 0; count = (n > 1) ? part[2] + 0 : 1
        remaining += count
        if (file == "") next
        hunked[parents, file] = 1
        for (i = first; i < first + count; i++) added[parents, file, i] = 1
      }
      next
    }
    {
      if (parents == 0 || $1 ~ /["\\]/) { print; next }
      for (p = 1; p <= parents; p++) {
        if (!((p, $1) in changed)) next
        if (!((p, $1) in hunked)) continue
        new = 0
        for (i = $2; i <= $3; i++) if ((p, $1, i) in added) new = 1
        if (!new) next
      }
      print
    }
  ' "$diff" "$list"
}

# needs_unstaged: whether the command can commit unstaged changes to tracked files. Reads
# the JSON-escaped command on stdin; exit 0 means scan them. It fails closed: the scan is
# skipped only when every `commit` word follows a git (or $VAR) word and every argument
# after it is a known option that can't add unstaged changes. Quoted strings count as one
# argument, and their contents are checked as commands too.
needs_unstaged() {
  awk '
    function decode(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") {
          c = substr(s, ++i, 1)
          if (c == "n") c = "\n"; else if (c == "t") c = " "; else if (c == "r") c = ""
          else if (c == "u") { i += 4; c = "?" }
        }
        out = out c
      }
      return out
    }
    # strip(s): s with shell backslash escapes resolved and each quoted string replaced by
    # " Q " (or by its text when that is a git or commit word); contents go to quoted[].
    function strip(s,   out, i, c, q, buf) {
      out = ""; q = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q == "") {
          if (c == "\"" || c == sq) { q = c; buf = ""; continue }
          if (c == "\\") { c = substr(s, ++i, 1); if (c == "\n") c = " " }
          out = out c
        } else if (c == "\\" && q == "\"") buf = buf substr(s, ++i, 1)
        else if (c == q) {
          quoted[++nquoted] = buf
          out = out ((buf ~ /^[^[:space:]]*(git(\.exe)?|commit)$/) ? buf : " Q ")
          q = ""
        } else buf = buf c
      }
      if (q != "") unterminated = 1
      return out
    }
    # check(s, strict): 1 when s may commit unstaged changes. strict is for the command
    # itself, where a subshell, command or process substitution, backtick or redirection
    # with & outside quotes means scan; inside a quoted string, any git ... commit does.
    function check(s, strict,   segs, nseg, k, t, nt, j, gitseen, tok, flags, m, ch, name, bare) {
      gsub(/`\n/, " ", s)
      if (strict) {
        bare = s; gsub(/&&/, "", bare)
        if (bare ~ /[()`&]/) return 1
      }
      gsub(/&&|\|\||[;&|()`\n]/, "\n", s)
      nseg = split(s, segs, "\n")
      for (k = 1; k <= nseg; k++) {
        nt = split(segs[k], t, /[[:space:]]+/)
        gitseen = 0
        for (j = 1; j <= nt; j++) {
          if (t[j] ~ /git(\.exe)?$/ || t[j] ~ /^\$/) { gitseen = 1; continue }
          if (t[j] == "commit") break
        }
        if (j > nt) continue
        if (!gitseen) { if (strict) return 1; continue }
        if (!strict) return 1
        for (j++; j <= nt; j++) {
          tok = t[j]
          if (tok == "") continue
          if (tok ~ /^[0-9]*[<>]/) { if (tok ~ /^[0-9]*[<>]+$/) j++; continue }
          if (tok ~ /^-[^-]/) {
            flags = substr(tok, 2)
            for (m = 1; m <= length(flags); m++) {
              ch = substr(flags, m, 1)
              if (ch ~ /[mFCct]/) { if (m == length(flags)) j++; break }
              if (ch ~ /[Su]/) break
              if (ch !~ /[enqsvz]/) return 1
            }
            continue
          }
          name = tok; sub(/=.*/, "", name)
          if (name ~ /^--(message|file|reuse-message|reedit-message|fixup|squash|author|date|template|cleanup|trailer)$/) { if (tok == name) j++; continue }
          if (name ~ /^--(untracked-files|gpg-sign)$/) continue
          if (tok ~ /^--(amend|no-edit|edit|signoff|no-signoff|no-verify|verify|allow-empty|allow-empty-message|dry-run|short|branch|porcelain|long|null|verbose|quiet|reset-author|no-gpg-sign|status|no-status|no-post-rewrite)$/) continue
          return 1
        }
      }
      return 0
    }
    BEGIN { sq = sprintf("%c", 39) }
    {
      cmd = strip(decode($0))
      if (unterminated || check(cmd, 1)) exit 0
      for (q = 1; q <= nquoted; q++) if (check(quoted[q], 0)) exit 0
      exit 1
    }
  '
}

# report <label> <gitleaks exit code> [findings list]: block on leaks or on a failed scan.
report() {
  local label=$1 rc=$2 list=${3:-} json=$report_dir/$1.json log=$report_dir/$1.log total all more="" skipped=""
  if [ "$rc" -eq 3 ]; then
    if [ -z "$list" ]; then
      list=$report_dir/$label.tsv
      findings "$json" >"$list"
    fi
    total=$(wc -l <"$list" | tr -d ' ')
    all=$(findings "$json" | wc -l | tr -d ' ')
    if [ "$total" -eq 0 ] && [ "$all" -gt 0 ]; then
      return 0
    fi
    if [ "$total" -lt "$all" ]; then
      skipped=$(printf ' (%s more are already on the branch being merged and were skipped)' "$((all - total))")
    fi
    if [ "$total" -gt "$max_findings" ]; then
      more=$(printf '\n...and %s more' "$((total - max_findings))")
    fi
    block "$(printf 'Blocked: gitleaks found %s secret(s) in the %s changes%s. Remove them (and rotate any real credential) before committing.\nFull redacted report, to inspect (for example with jq) instead of re-running the scan: %s\n%s%s' \
      "$total" "$label" "$skipped" "$(show_path "$json")" \
      "$(head -n "$max_findings" "$list" | awk -F '\t' '{ print $1 ":" $2 "  " $4 "  " $5 }' | cut -c "1-$max_line")" "$more")"
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
scan staged --staged
rc=$?
if [ "$rc" -eq 3 ] && git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  findings "$report_dir/staged.json" >"$report_dir/staged.all.tsv"
  new_in_merge "$report_dir/staged.all.tsv" >"$report_dir/staged.tsv"
  report staged "$rc" "$report_dir/staged.tsv"
else
  report staged "$rc"
fi

# Unstaged changes to tracked files: `git commit -a`, `--all`, or a pathspec commits them too.
if json_field command | needs_unstaged; then
  scan unstaged
  report unstaged $?
fi

rm -rf "$report_dir"
exit 0
