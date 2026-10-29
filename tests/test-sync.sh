#!/usr/bin/env bash
# Tests for install/sync.sh against a throwaway config directory.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo=$TMP_ROOT/repo
target=$TMP_ROOT/claude
make_repo_copy "$repo"
mkdir -p "$target"
cat >"$target/settings.json" <<'EOF'
{
  "statusLine": {"type": "command", "command": "status.sh"},
  "permissions": {"deny": ["Bash(rm -rf *)"], "allow": ["Bash(ls *)"]},
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "notify.sh"}]}]},
  "effortLevel": "low"
}
EOF
sync() { bash "$repo/install/sync.sh" --target "$target" "$@"; }
settings() { jq -c "$1" "$target/settings.json"; }

# Fresh install
out=$(sync 2>&1); rc=$?
assert_eq "fresh install exits 0" 0 "$rc"
assert_file "CLAUDE.md installed" "$target/CLAUDE.md"
assert_file "rule installed" "$target/rules/github-actions.md"
assert_file "command installed" "$target/commands/create-pr.md"
assert_file "hook installed" "$target/hooks/claude-shit/secret-scan.sh"
assert_file "nested agent installed" "$target/agents/core/debugger.md"
assert_file "manifest written" "$target/.claude-shit/manifest.tsv"
assert_eq "local scalar kept" '{"type":"command","command":"status.sh"}' "$(settings .statusLine)"
assert_eq "shared scalar replaces local" '"xhigh"' "$(settings .effortLevel)"
assert_eq "local deny entry kept" true "$(settings '.permissions.deny | index("Bash(rm -rf *)") != null')"
assert_eq "shared deny entry added" true "$(settings '.permissions.deny | index("Bash(helm install *)") != null')"
assert_eq "local allow kept" '["Bash(ls *)"]' "$(settings .permissions.allow)"
assert_eq "local Stop hook kept" 1 "$(settings '.hooks.Stop | length')"
assert_eq "attribution set" '{"commit":"","pr":""}' "$(settings .attribution)"
hook_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$target/settings.json")
assert_not_contains "hook path placeholder replaced" "__CLAUDE_SHIT_HOOKS__" "$hook_cmd"
assert_contains "hook path points at target" "hooks/claude-shit/secret-scan.sh" "$hook_cmd"

# Second run is a no-op
out=$(sync 2>&1); rc=$?
assert_eq "rerun exits 0" 0 "$rc"
assert_contains "rerun reports up to date" "Up to date." "$out"
assert_eq "rerun adds no duplicate hooks" 1 "$(settings '.hooks.PreToolUse | length')"
assert_eq "secret scan covers PowerShell commits" 1 "$(settings '[.hooks.PreToolUse[] | select(.matcher | test("PowerShell")) | .hooks[] | select(.if == "PowerShell(git commit *)" and (.command | contains("secret-scan.sh")))] | length')"

# --check writes nothing and exits 1 when out of date
printf '\n- extra rule\n' >>"$repo/claude_md/CLAUDE.md"
before=$(cat "$target/CLAUDE.md")
out=$(sync --check 2>&1); rc=$?
assert_eq "check exits 1 when pending" 1 "$rc"
assert_contains "check lists the update" "UPDATE  CLAUDE.md" "$out"
assert_eq "check leaves file untouched" "$before" "$(cat "$target/CLAUDE.md")"

# Update propagates, with a backup
out=$(sync 2>&1); rc=$?
assert_eq "update exits 0" 0 "$rc"
assert_contains "updated CLAUDE.md has new line" "extra rule" "$(cat "$target/CLAUDE.md")"
assert_eq "backup created" 1 "$(find "$target/backups/claude-shit" -name CLAUDE.md | wc -l | tr -d ' ')"

# Removing things from the repo removes them locally, but only what the repo added
rm "$repo/rules/github-actions.md"
jq '.permissions.deny -= ["Bash(helm install *)"]' "$repo/settings/settings.shared.json" >"$TMP_ROOT/s.json" \
  && mv "$TMP_ROOT/s.json" "$repo/settings/settings.shared.json"
out=$(sync 2>&1); rc=$?
assert_eq "removal sync exits 0" 0 "$rc"
assert_no_file "removed rule deleted" "$target/rules/github-actions.md"
assert_eq "removed deny entry dropped" false "$(settings '.permissions.deny | index("Bash(helm install *)") != null')"
assert_eq "local deny entry survives removal" true "$(settings '.permissions.deny | index("Bash(rm -rf *)") != null')"

# A locally edited file is not overwritten without --force
printf '\nlocal note\n' >>"$target/CLAUDE.md"
printf '\n- another rule\n' >>"$repo/claude_md/CLAUDE.md"
out=$(sync 2>&1); rc=$?
assert_eq "drift exits 3" 3 "$rc"
assert_contains "drift reported" "SKIP    CLAUDE.md" "$out"
assert_contains "local edit kept" "local note" "$(cat "$target/CLAUDE.md")"
out=$(sync --force 2>&1); rc=$?
assert_eq "force exits 0" 0 "$rc"
assert_not_contains "force overwrites local edit" "local note" "$(cat "$target/CLAUDE.md")"
assert_contains "force installs repo version" "another rule" "$(cat "$target/CLAUDE.md")"

# Keys the repo stops shipping: local additions and changes survive, untouched values go
jq '.permissions.ask += ["Bash(rm -rf *)"] | .effortLevel = "medium"' "$target/settings.json" >"$TMP_ROOT/s.json" \
  && mv "$TMP_ROOT/s.json" "$target/settings.json"
jq 'del(.permissions.ask, .effortLevel, .outputStyle)' "$repo/settings/settings.shared.json" >"$TMP_ROOT/s.json" \
  && mv "$TMP_ROOT/s.json" "$repo/settings/settings.shared.json"
out=$(sync 2>&1); rc=$?
assert_eq "dropped-key sync exits 0" 0 "$rc"
assert_eq "local ask entry kept after repo drops ask" '["Bash(rm -rf *)"]' "$(settings .permissions.ask)"
assert_eq "locally changed scalar kept after repo drops it" '"medium"' "$(settings .effortLevel)"
assert_eq "untouched scalar removed with the repo key" 'null' "$(settings .outputStyle)"

# A missing source directory doesn't remove files from the other directories
rm -rf "$repo/rules" "$repo/commands"
out=$(sync 2>&1); rc=$?
assert_eq "sync without rules/commands exits 0" 0 "$rc"
assert_file "hooks kept when rules/ is missing" "$target/hooks/claude-shit/secret-scan.sh"
assert_file "agents kept when rules/ is missing" "$target/agents/core/debugger.md"
assert_no_file "commands removed with their directory" "$target/commands/create-pr.md"

# Key order inside an array entry doesn't create duplicates
jq '.hooks.PreToolUse[0] |= (to_entries | reverse | from_entries)' "$target/settings.json" >"$TMP_ROOT/s.json" \
  && mv "$TMP_ROOT/s.json" "$target/settings.json"
out=$(sync 2>&1)
assert_eq "reordered hook entry not duplicated" 1 "$(settings '.hooks.PreToolUse | length')"

# An empty settings.json is treated as {}
: >"$target/settings.json"
out=$(sync 2>&1); rc=$?
assert_eq "empty settings.json syncs" 0 "$rc"
assert_eq "empty settings.json gets shared keys" '{"commit":"","pr":""}' "$(settings .attribution)"

# A relative --target still writes absolute hook paths
rel_target=rel-claude
out=$(cd "$TMP_ROOT" && bash "$repo/install/sync.sh" --target "$rel_target" 2>&1); rc=$?
assert_eq "relative target exits 0" 0 "$rc"
rel_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$TMP_ROOT/$rel_target/settings.json")
case $rel_cmd in
  'bash "/'* | 'bash "'[A-Za-z]:/*) pass "relative target gives absolute hook path" ;;
  *) fail "relative target gives absolute hook path" "$rel_cmd" ;;
esac

# Invalid settings.json is left alone
printf '{ not json' >"$target/settings.json"
out=$(sync 2>&1); rc=$?
assert_eq "invalid settings fails" 1 "$rc"
assert_eq "invalid settings untouched" "{ not json" "$(cat "$target/settings.json")"

finish
