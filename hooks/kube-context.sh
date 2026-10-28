#!/usr/bin/env bash
# Claude Code PreToolUse hook for Bash calls, configured twice: with
# `if: "Bash(kubectl *)"` and argument `kubectl`, and with `if: "Bash(helm *)"` and
# argument `helm`. Adds the active kubectl context to Claude's context so it can
# confirm the command targets the intended cluster. Never blocks the call.
# Claude Code also runs `if`-filtered hooks for commands it can't fully parse, so the
# hook checks that the command really runs the tool named in its argument.
# Its output goes into Claude's context, so kubectl's text is capped at 300 bytes.
set -u

tool=${1:-kubectl}
input=$(cat)
cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | head -n 1)
if ! printf '%s' "$cmd" | grep -Eq "(^|[^[:alnum:]_.-])${tool}([[:space:]]|\\\\|\$)"; then
  exit 0
fi

json_escape() { # newlines and tabs become spaces; other control characters are dropped
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

if ! command -v kubectl >/dev/null 2>&1; then
  msg="kubectl is not installed on this machine, so the active cluster context could not be checked."
elif ctx=$(kubectl config current-context 2>&1 | head -c 300; exit "${PIPESTATUS[0]}"); then
  msg="Active kubectl context: ${ctx}. Confirm this is the intended cluster before running cluster commands; if it isn't, run kubectl config use-context <name> and check current-context again."
else
  msg="kubectl config current-context failed: ${ctx}. Set the intended context with kubectl config use-context <name> before running cluster commands."
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$(json_escape "$msg")"
exit 0
