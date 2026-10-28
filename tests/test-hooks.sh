#!/usr/bin/env bash
# Tests for the hook scripts, using stub gitleaks and kubectl binaries.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hooks=$REPO_ROOT/hooks
stubs=$TMP_ROOT/bin
mkdir -p "$stubs"
calls=$TMP_ROOT/gitleaks-calls

# The stub writes STUB_FINDINGS findings (default 1) to --report-path in gitleaks' JSON
# layout and STUB_LOG_LINES lines (default 1) to its output.
cat >"$stubs/gitleaks" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$calls"
report=
while [ \$# -gt 0 ]; do
  if [ "\$1" = --report-path ]; then report=\$2; fi
  shift
done
awk -v n="\${STUB_LOG_LINES:-1}" 'BEGIN { for (i = 1; i <= n; i++) print "stub gitleaks output " i }'
if [ -n "\$report" ]; then
  n=\${STUB_FINDINGS:-1}
  [ "\${STUB_RC:-0}" -eq 3 ] || n=0
  awk -v n="\$n" 'BEGIN {
    print "["
    for (i = 1; i <= n; i++) {
      printf " {\n  \"RuleID\": \"generic-api-key\",\n  \"StartLine\": %d,\n  \"Secret\": \"REDACTED\",\n", i
      printf "  \"File\": \"dir/file%d.py\",\n  \"Fingerprint\": \"dir/file%d.py:generic-api-key:%d\"\n }%s\n", i, i, i, (i < n ? "," : "")
    }
    print "]"
  }' >"\$report"
fi
exit \${STUB_RC:-0}
EOF
chmod +x "$stubs/gitleaks"

repo=$TMP_ROOT/work
git init -q "$repo"
json_cwd=$repo
if command -v cygpath >/dev/null 2>&1; then
  json_cwd=$(cygpath -w "$repo" | sed 's/\\/\\\\/g')
fi
input() { # input <command>
  printf '{"cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$json_cwd" "$1"
}
hook_tmp=$TMP_ROOT/hook-tmp
mkdir -p "$hook_tmp"
scan() { # scan <command> -> sets rc, err, ncalls
  : >"$calls"
  err=$(input "$1" | (cd "$TMP_ROOT" && TMPDIR=$hook_tmp PATH="$stubs:$PATH" bash "$hooks/secret-scan.sh") 2>&1 >/dev/null)
  rc=$?
  ncalls=$(wc -l <"$calls" | tr -d ' ')
}

# secret-scan.sh
STUB_RC=0 scan 'git commit -m \"fix a bug\"'
assert_eq "clean commit allowed" 0 "$rc"
assert_eq "staged and unstaged changes scanned" 2 "$ncalls"
assert_contains "scan uses --staged" "--staged" "$(cat "$calls")"

STUB_RC=0 scan 'git add . && git commit -m \"msg\"'
assert_eq "chained add and commit blocked" 2 "$rc"
assert_contains "chained add message" "stages files and commits in one step" "$err"
assert_eq "chained add not scanned" 0 "$ncalls"

STUB_RC=0 scan 'git -C sub stage -A; git commit -m x'
assert_eq "chained git stage with options blocked" 2 "$rc"

STUB_RC=0 scan 'git add\\\nfile.txt; git commit -m x'
assert_eq "line-continued git add then commit blocked" "2:0" "$rc:$ncalls"

STUB_RC=0 scan 'git commit -m \"address review\"'
assert_eq "commit message mentioning address is allowed" 0 "$rc"

# Claude Code also runs if-filtered hooks for commands it can't parse; those must pass through.
# shellcheck disable=SC2016 # the $ is part of the command text under test
STUB_RC=3 scan 'git switch -c fix/x && echo \"$LOCALAPPDATA\"'
assert_eq "non-commit command passes through" 0 "$rc"
assert_eq "non-commit command not scanned" 0 "$ncalls"

STUB_RC=3 scan 'git log --oneline -5'
assert_eq "git log passes through" 0 "$rc"

STUB_RC=0 scan 'git -C sub commit -m x'
assert_eq "git -C dir commit is scanned" 2 "$ncalls"

STUB_RC=0 scan 'git \\\ncommit -m x'
assert_eq "line-continued git commit is scanned" 2 "$ncalls"

STUB_RC=0 scan 'git\tcommit -m x'
assert_eq "tab-separated git commit is scanned" 2 "$ncalls"

STUB_RC=3 scan 'echo commit'
assert_eq "any command mentioning commit is scanned (fail closed)" 2 "$rc"

export STUB_RC=3
scan 'git commit -m \"x\"'
assert_eq "leak blocks commit" 2 "$rc"
assert_contains "leak message" "gitleaks found 1 secret(s) in the staged changes" "$err"
assert_contains "leak lists the finding" "dir/file1.py:1  generic-api-key  dir/file1.py:generic-api-key:1" "$err"
assert_not_contains "leak hides the gitleaks log" "stub gitleaks output" "$err"
assert_not_contains "single leak has no overflow line" "more" "$err"

# report_path <hook stderr>: the report path the hook printed, in a form bash can open.
report_path() {
  local p
  p=$(printf '%s\n' "$1" | sed -n 's/^Full [^:]*: //p' | head -n 1)
  if command -v cygpath >/dev/null 2>&1 && [ -n "$p" ]; then cygpath -u "$p"; else printf '%s' "$p"; fi
}

# A merge can stage thousands of files: output stays bounded however many findings there are.
STUB_FINDINGS=2000 STUB_LOG_LINES=5000 scan 'git commit -m \"x\"'
assert_eq "many leaks block commit" 2 "$rc"
assert_eq "many leaks output under 4 KB" yes "$([ "$(printf '%s' "$err" | wc -c)" -lt 4096 ] && echo yes || echo "no: $(printf '%s' "$err" | wc -c) bytes")"
assert_contains "many leaks total count" "found 2000 secret(s)" "$err"
assert_eq "many leaks list 10 findings" 10 "$(printf '%s\n' "$err" | grep -c 'generic-api-key:')"
assert_contains "many leaks overflow line" "...and 1990 more" "$err"
report=$(report_path "$err")
assert_file "many leaks report file kept" "$report"
assert_eq "report file holds every finding" 2000 "$(grep -c '"Fingerprint"' "$report" 2>/dev/null)"
assert_contains "report file is per-run temp" "$hook_tmp/secret-scan." "$report"

STUB_RC=1
STUB_LOG_LINES=5000 scan 'git commit -m \"x\"'
assert_eq "gitleaks error blocks commit" 2 "$rc"
assert_contains "error message" "scan of the staged changes failed" "$err"
assert_eq "error output under 4 KB" yes "$([ "$(printf '%s' "$err" | wc -c)" -lt 4096 ] && echo yes || echo no)"
assert_contains "error shows last log line" "stub gitleaks output 5000" "$err"
assert_not_contains "error hides early log lines" "stub gitleaks output 4990" "$err"
assert_file "error log file kept" "$(report_path "$err")"
unset STUB_RC

rm -rf "${hook_tmp:?}"/*
STUB_RC=0 scan 'git commit -m x'
assert_eq "clean commit leaves no temp folder" "" "$(ls -A "$hook_tmp")"

# Without gitleaks on PATH or in a known install folder, commits are blocked.
empty_home=$TMP_ROOT/empty-home
mkdir -p "$empty_home"
if command -v gitleaks >/dev/null 2>&1 || [ -x /usr/local/bin/gitleaks ] || [ -x /home/linuxbrew/.linuxbrew/bin/gitleaks ]; then
  printf 'skip  missing-gitleaks case (gitleaks is installed on this machine)\n'
else
  err=$(input 'git commit -m x' | (cd "$TMP_ROOT" && LOCALAPPDATA='' HOME=$empty_home bash "$hooks/secret-scan.sh") 2>&1 >/dev/null); rc=$?
  assert_eq "missing gitleaks blocks commit" 2 "$rc"
  assert_contains "missing gitleaks message" "gitleaks is not installed" "$err"
fi

# gitleaks installed by winget but not yet on the app's PATH is still found.
fake_lad=$TMP_ROOT/LocalAppData
pkg=$fake_lad/Microsoft/WinGet/Packages/Gitleaks.Gitleaks_Microsoft.Winget.Source_test
mkdir -p "$pkg"
cp "$stubs/gitleaks" "$pkg/gitleaks.exe"
: >"$calls"
if command -v gitleaks >/dev/null 2>&1; then
  printf 'skip  off-PATH gitleaks case (gitleaks is on PATH on this machine)\n'
else
  err=$(input 'git commit -m x' | (cd "$TMP_ROOT" && LOCALAPPDATA=$fake_lad HOME=$empty_home STUB_RC=0 bash "$hooks/secret-scan.sh") 2>&1 >/dev/null); rc=$?
  assert_eq "winget gitleaks off PATH is used" 0 "$rc"
  assert_eq "winget gitleaks ran both scans" 2 "$(wc -l <"$calls" | tr -d ' ')"
fi

# Real gitleaks (GITLEAKS_BIN, or gitleaks on PATH): hundreds of fake keys in a temp repo.
real_gitleaks=${GITLEAKS_BIN:-$(command -v gitleaks 2>/dev/null)}
if [ -z "$real_gitleaks" ] || [ ! -x "$real_gitleaks" ]; then
  printf 'skip  real gitleaks cases (set GITLEAKS_BIN or put gitleaks on PATH)\n'
else
  real_bin=$TMP_ROOT/real-bin
  mkdir -p "$real_bin"
  cp "$real_gitleaks" "$real_bin/gitleaks"
  leaky=$TMP_ROOT/leaky
  git init -q "$leaky"
  git -C "$leaky" config core.autocrlf false
  leaky_cwd=$leaky
  command -v cygpath >/dev/null 2>&1 && leaky_cwd=$(cygpath -w "$leaky" | sed 's/\\/\\\\/g')
  real_scan() { # real_scan -> sets rc, err
    err=$(printf '{"cwd":"%s","tool_input":{"command":"git commit -m x"}}' "$leaky_cwd" \
      | (cd "$leaky" && TMPDIR=$hook_tmp PATH="$real_bin:$PATH" bash "$hooks/secret-scan.sh") 2>&1 >/dev/null)
    rc=$?
  }
  echo "hello" >"$leaky/readme.txt"
  git -C "$leaky" add readme.txt
  real_scan
  assert_eq "real gitleaks: clean commit allowed" "0:" "$rc:$err"

  # 300 fake AWS access key IDs across 30 files (gitleaks skips the rare low-entropy one).
  head -c 200000 /dev/urandom | LC_ALL=C tr -dc 'A-Z2-7' | fold -w 16 | head -n 300 \
    | awk -v dir="$leaky" '{ printf "aws_key = \"AKIA%s\"\n", $0 > (dir "/conf" (NR % 30) ".py") }'
  git -C "$leaky" add .
  real_scan
  bytes=$(printf '%s' "$err" | wc -c | tr -d ' ')
  assert_eq "real gitleaks: many secrets block commit" 2 "$rc"
  assert_eq "real gitleaks: output under 4 KB" yes "$([ "$bytes" -lt 4096 ] && echo yes || echo "no: $bytes bytes")"
  assert_eq "real gitleaks: 10 findings listed" 10 "$(printf '%s\n' "$err" | grep -c '^conf[0-9]*\.py:')"
  report=$(report_path "$err")
  total=$(printf '%s\n' "$err" | sed -n 's/.*found \([0-9]*\) secret.*/\1/p')
  assert_eq "real gitleaks: report holds every finding" "$total" "$(grep -c '"Fingerprint"' "$report" 2>/dev/null)"
  assert_eq "real gitleaks: hundreds of findings" yes "$([ "${total:-0}" -ge 200 ] && echo yes || echo "no: $total")"
  assert_eq "real gitleaks: report is redacted" 0 "$(grep -c 'AKIA[A-Z2-7]\{16\}' "$report")"
  printf '      real gitleaks output: %s bytes, %s findings\n' "$bytes" "$total"
fi

notrepo=$TMP_ROOT/notrepo
mkdir -p "$notrepo"
nr_cwd=$notrepo
command -v cygpath >/dev/null 2>&1 && nr_cwd=$(cygpath -w "$notrepo" | sed 's/\\/\\\\/g')
printf '{"cwd":"%s","tool_input":{"command":"git commit -m x"}}' "$nr_cwd" \
  | (cd "$notrepo" && PATH="$stubs:$PATH" bash "$hooks/secret-scan.sh") 2>/dev/null; rc=$?
assert_eq "outside a repository the hook steps aside" 0 "$rc"

# kube-context.sh
cat >"$stubs/kubectl" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_FAIL:-}" ]; then echo "error: current-context is not set" >&2; exit 1; fi
echo "${STUB_CTX:-do-nyc1-prod}"
EOF
chmod +x "$stubs/kubectl"
kube() { # kube [command] [tool]
  printf '{"tool_input":{"command":"%s"}}' "${1:-kubectl get pods}" | PATH="$stubs:$PATH" bash "$hooks/kube-context.sh" "${2:-kubectl}"
}
context() { printf '%s' "$1" | jq -r .hookSpecificOutput.additionalContext; }

out=$(kube); rc=$?
assert_eq "kube hook exits 0" 0 "$rc"
assert_eq "kube hook emits valid JSON" '"PreToolUse"' "$(printf '%s' "$out" | jq -c .hookSpecificOutput.hookEventName)"
assert_contains "kube hook names context" "do-nyc1-prod" "$(context "$out")"

out=$(STUB_CTX='we"ird\ctx' kube)
assert_eq "context with quotes stays valid JSON" 'Active kubectl context: we"ird\ctx.' "$(context "$out" | cut -d' ' -f1-4)"

out=$(STUB_CTX="$(printf 'tab\there')" kube)
assert_contains "context with a tab stays valid JSON" "tab here" "$(context "$out")"

# shellcheck disable=SC2016 # the $ is part of the command text under test
out=$(kube 'git status && echo \"$HOME\"' kubectl); rc=$?
assert_eq "kube hook ignores non-kubectl command" "0:" "$rc:$out"

out=$(kube 'kubectl -n prod get pods' helm)
assert_eq "helm hook ignores kubectl-only command" "" "$out"

out=$(kube 'helm --kube-context x list' helm)
assert_contains "helm hook reports context" "do-nyc1-prod" "$(context "$out")"

out=$(STUB_CTX="$(printf 'x%.0s' $(seq 1 5000))" kube)
assert_eq "kube hook caps kubectl output" yes "$([ "$(context "$out" | wc -c)" -lt 600 ] && echo yes || echo no)"

out=$(STUB_FAIL=1 kube); rc=$?
assert_eq "kube failure still exits 0" 0 "$rc"
assert_contains "kube failure reported" "current-context is not set" "$(context "$out")"

finish
