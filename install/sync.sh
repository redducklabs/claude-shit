#!/usr/bin/env bash
# Sync this repository's Claude Code configuration into ~/.claude (Linux, WSL, macOS).
# Windows uses install/sync.ps1, which implements the same behavior.
#
# Usage: install/sync.sh [--check] [--force] [--target DIR]
#   --check   report what would change; write nothing; exit 1 if anything is out of date
#   --force   overwrite or remove files that were edited locally since the last sync
#   --target  config directory (default: $CLAUDE_CONFIG_DIR, else ~/.claude)
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CHECK=0
FORCE=0

while [ $# -gt 0 ]; do
  case $1 in
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    --target) TARGET=${2:?--target needs a directory}; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "error: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required (Debian/Ubuntu: sudo apt install jq; macOS: brew install jq)"
if command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "sha256sum or shasum is required"
fi

STATE=$TARGET/.claude-shit
MANIFEST=$STATE/manifest.tsv
APPLIED=$STATE/applied-settings.json
BACKUP=$TARGET/backups/claude-shit/$(date +%Y%m%d-%H%M%S)
HOOKS_DIR=$TARGET/hooks/claude-shit
PENDING=0
DRIFT=0

say() { printf '%s\n' "$*"; }

backup() { # backup <relative path under TARGET>
  mkdir -p "$(dirname "$BACKUP/$1")"
  cp -p "$TARGET/$1" "$BACKUP/$1"
}

# Previous manifest: "<relative dest>\t<sha256 at last sync>"
declare -A OLD=()
if [ -f "$MANIFEST" ]; then
  while IFS=$'\t' read -r path hash; do
    [ -n "$path" ] && OLD[$path]=$hash
  done <"$MANIFEST"
fi
declare -A NEW=()

# Source file -> destination relative to TARGET.
mapping() {
  printf '%s\t%s\n' "claude_md/CLAUDE.md" "CLAUDE.md"
  (cd "$REPO" && find rules commands -type f -name '*.md' 2>/dev/null | sort) | while read -r f; do
    printf '%s\t%s\n' "$f" "$f"
  done
  (cd "$REPO" && find hooks -type f -name '*.sh' | sort) | while read -r f; do
    printf '%s\t%s\n' "$f" "hooks/claude-shit/${f#hooks/}"
  done
  (cd "$REPO" && find agents -type f -name '*.md' | sort) | while read -r f; do
    printf '%s\t%s\n' "$f" "$f"
  done
}

sync_file() { # sync_file <src relative to REPO> <dest relative to TARGET>
  local src=$REPO/$1 rel=$2 dest=$TARGET/$2 want have
  want=$(sha "$src")
  if [ -f "$dest" ]; then
    have=$(sha "$dest")
    if [ "$have" = "$want" ]; then
      NEW[$rel]=$want
      return
    fi
    if [ -n "${OLD[$rel]:-}" ] && [ "${OLD[$rel]}" != "$have" ] && [ $FORCE -eq 0 ]; then
      say "SKIP    $rel (edited locally since the last sync; port the edit to the repo or rerun with --force)"
      NEW[$rel]=${OLD[$rel]}
      DRIFT=1
      return
    fi
    PENDING=1
    say "UPDATE  $rel"
    if [ $CHECK -eq 0 ]; then
      backup "$rel"
      cp "$src" "$dest"
    fi
  else
    PENDING=1
    say "ADD     $rel"
    if [ $CHECK -eq 0 ]; then
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
    fi
  fi
  NEW[$rel]=$want
}

while IFS=$'\t' read -r src rel; do
  sync_file "$src" "$rel"
done < <(mapping)

# Files this repo installed before but no longer ships.
for rel in "${!OLD[@]}"; do
  [ -n "${NEW[$rel]:-}" ] && continue
  dest=$TARGET/$rel
  [ -f "$dest" ] || continue
  if [ "$(sha "$dest")" != "${OLD[$rel]}" ] && [ $FORCE -eq 0 ]; then
    say "KEEP    $rel (removed from the repo but edited locally; delete it yourself or rerun with --force)"
    DRIFT=1
    continue
  fi
  PENDING=1
  say "REMOVE  $rel"
  if [ $CHECK -eq 0 ]; then
    backup "$rel"
    rm "$dest"
  fi
done

# settings.json: drop entries an earlier sync added that the repo no longer has, then
# merge the shared settings in. Objects merge by key, arrays by union, scalars are replaced.
hooks_path=$HOOKS_DIR
if command -v cygpath >/dev/null 2>&1; then hooks_path=$(cygpath -m "$HOOKS_DIR"); fi
shared=$(jq --arg dir "$hooks_path" 'walk(if type == "string" then gsub("__CLAUDE_SHIT_HOOKS__"; $dir) else . end)' "$REPO/settings/settings.shared.json") \
  || die "settings/settings.shared.json is not valid JSON"
settings=$TARGET/settings.json
current='{}'
if [ -f "$settings" ]; then
  current=$(jq '.' "$settings") || die "$settings is not valid JSON; fix it before syncing"
fi
previous='{}'
[ -f "$APPLIED" ] && previous=$(jq '.' "$APPLIED")

merged=$(jq -n --argjson cur "$current" --argjson prev "$previous" --argjson new "$shared" '
  def strip($p; $n):
    if type == "object" and ($p | type) == "object" then
      reduce ($p | keys_unsorted[]) as $k (.;
        if ($n | type) == "object" and ($n | has($k)) then
          (if has($k) then .[$k] |= strip($p[$k]; $n[$k]) else . end)
        else del(.[$k]) end)
    elif type == "array" and ($p | type) == "array" then
      map(. as $x | select((any($p[]; . == $x) | not) or (($n | type) == "array" and any($n[]; . == $x))))
    else . end;
  def merge($n):
    if type == "object" and ($n | type) == "object" then
      reduce ($n | keys_unsorted[]) as $k (.;
        .[$k] = (if has($k) then (.[$k] | merge($n[$k])) else $n[$k] end))
    elif type == "array" and ($n | type) == "array" then
      reduce $n[] as $x (.; if any(.[]; . == $x) then . else . + [$x] end)
    else $n end;
  $cur | strip($prev; $new) | merge($new)')

if [ "$(jq -S . <<<"$merged")" != "$(jq -S . <<<"$current")" ]; then
  PENDING=1
  say "UPDATE  settings.json"
  if [ $CHECK -eq 0 ]; then
    [ -f "$settings" ] && backup settings.json
    printf '%s\n' "$merged" >"$settings"
  fi
fi

if [ $CHECK -eq 0 ]; then
  mkdir -p "$STATE"
  : >"$MANIFEST"
  for rel in "${!NEW[@]}"; do printf '%s\t%s\n' "$rel" "${NEW[$rel]}"; done | sort >"$MANIFEST"
  printf '%s\n' "$shared" >"$APPLIED"
  printf '%s\n' "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)" >"$STATE/synced-commit"
  [ -d "$BACKUP" ] && say "Backups of replaced files: $BACKUP"
fi

for tool in gitleaks kubectl; do
  command -v "$tool" >/dev/null 2>&1 || say "WARN    $tool not found. $([ "$tool" = gitleaks ] && echo 'The secret-scan hook blocks every git commit until it is installed.' || echo 'The kube-context hook will report it missing.')"
done

if [ $PENDING -eq 0 ] && [ $DRIFT -eq 0 ]; then
  say "Up to date."
elif [ $CHECK -eq 1 ] && [ $PENDING -eq 1 ]; then
  exit 1
fi
[ $DRIFT -eq 1 ] && exit 3
exit 0
