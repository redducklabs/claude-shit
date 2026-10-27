# claude-shit

Shared Claude Code config, installed into `~/.claude` by `install/sync.sh` (Linux/WSL) and `install/sync.ps1` (Windows). The two scripts must behave identically; see README.md.

## Commands
- `bash tests/test-sync.sh` and `bash tests/test-hooks.sh`
- `powershell -NoProfile -File tests/test-sync.ps1` (includes a check that both sync scripts produce identical settings.json)
- `shellcheck -x -P SCRIPTDIR install/sync.sh hooks/*.sh tests/*.sh`

## Gotchas
- From PowerShell, call jq through Git Bash (`'' | & bash -c 'jq ...'`), not `& jq`. A jq installed without an `.exe` extension (as on the main dev machine) resolves in PowerShell but returns no output, so comparisons pass vacuously.
- Give bash empty stdin (`'' | & bash ...`) when PowerShell starts it from inside a Git Bash session; otherwise it can block indefinitely.
- Windows PowerShell 5.1 turns native stderr into a terminating error under `$ErrorActionPreference = 'Stop'`; set it to `'Continue'` around native calls that write to stderr.
- `Invoke-ScriptAnalyzer -Path` takes one path; loop over files.
