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
assert_eq "staged changes scanned once" 1 "$ncalls"
assert_contains "scan uses --staged" "--staged" "$(cat "$calls")"

STUB_RC=0 scan 'git commit -am \"msg\"'
assert_eq "commit -am allowed when clean" 0 "$rc"
assert_eq "commit -am also scans unstaged" 2 "$ncalls"

STUB_RC=0 scan 'git commit --all -m \"msg\"'
assert_eq "commit --all also scans unstaged" 2 "$ncalls"

STUB_RC=0 scan 'git commit --amend --no-edit'
assert_eq "commit --amend scans staged only" 1 "$ncalls"

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

if command -v gitleaks >/dev/null 2>&1; then
  printf 'skip  missing-gitleaks case (gitleaks is installed on this machine)\n'
else
  err=$(input 'git commit -m x' | bash "$hooks/secret-scan.sh" 2>&1 >/dev/null); rc=$?
  assert_eq "missing gitleaks blocks commit" 2 "$rc"
  assert_contains "missing gitleaks message" "gitleaks is not installed" "$err"
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
kube() { echo '{}' | PATH="$stubs:$PATH" bash "$hooks/kube-context.sh"; }

out=$(kube); rc=$?
assert_eq "kube hook exits 0" 0 "$rc"
assert_eq "kube hook emits valid JSON" '"PreToolUse"' "$(printf '%s' "$out" | jq -c .hookSpecificOutput.hookEventName)"
assert_contains "kube hook names context" "do-nyc1-prod" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)"

out=$(STUB_CTX='we"ird\ctx' kube)
assert_eq "context with quotes stays valid JSON" 'Active kubectl context: we"ird\ctx.' \
  "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext | cut -d' ' -f1-4)"

out=$(STUB_FAIL=1 kube); rc=$?
assert_eq "kube failure still exits 0" 0 "$rc"
assert_contains "kube failure reported" "current-context is not set" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)"

finish
