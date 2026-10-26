#!/usr/bin/env bash
# Claude Code PreToolUse hook, run for Bash calls matching `kubectl *` or `helm *`.
# Adds the active kubectl context to Claude's context so it can confirm the
# command targets the intended cluster. Never blocks the call.
set -u

cat >/dev/null # hook input is not needed

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'
}

if ! command -v kubectl >/dev/null 2>&1; then
  msg="kubectl is not installed on this machine, so the active cluster context could not be checked."
elif ctx=$(kubectl config current-context 2>&1); then
  msg="Active kubectl context: ${ctx}. Confirm this is the intended cluster before running cluster commands; if it isn't, run kubectl config use-context <name> and check current-context again."
else
  msg="kubectl config current-context failed: ${ctx}. Set the intended context with kubectl config use-context <name> before running cluster commands."
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$(json_escape "$msg")"
exit 0
