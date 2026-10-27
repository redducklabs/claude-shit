#!/usr/bin/env bash
# Tests for the hook scripts, using stub gitleaks and kubectl binaries.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hooks=$REPO_ROOT/hooks
stubs=$TMP_ROOT/bin
mkdir -p "$stubs"
calls=$TMP_ROOT/gitleaks-calls

cat >"$stubs/gitleaks" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$calls"
echo "stub gitleaks output"
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
scan() { # scan <command> -> sets rc, err, ncalls
  : >"$calls"
  err=$(input "$1" | (cd "$TMP_ROOT" && PATH="$stubs:$PATH" bash "$hooks/secret-scan.sh") 2>&1 >/dev/null)
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

export STUB_RC=3
scan 'git commit -m \"x\"'
assert_eq "leak blocks commit" 2 "$rc"
assert_contains "leak message" "found secrets" "$err"
assert_contains "leak shows gitleaks output" "stub gitleaks output" "$err"

STUB_RC=1
scan 'git commit -m \"x\"'
assert_eq "gitleaks error blocks commit" 2 "$rc"
assert_contains "error message" "scan of the staged changes failed" "$err"
unset STUB_RC

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

out=$(STUB_FAIL=1 kube); rc=$?
assert_eq "kube failure still exits 0" 0 "$rc"
assert_contains "kube failure reported" "current-context is not set" "$(context "$out")"

finish
