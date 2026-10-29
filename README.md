# claude-shit

Claude Code configuration shared across all of my machines: global instructions, rules, hooks, settings, agents, and commands. A sync script installs it into `~/.claude` and keeps it current.

## What gets installed

| Repo path | Installed to | Purpose |
|---|---|---|
| `claude_md/CLAUDE.md` | `~/.claude/CLAUDE.md` | Global instructions for every project |
| `rules/**/*.md` | `~/.claude/rules/` | Personal rules; `paths:` frontmatter limits a rule to matching files |
| `hooks/**/*.sh` | `~/.claude/hooks/claude-shit/` | Hook scripts (see [Hooks](#hooks)) |
| `settings/settings.shared.json` | merged into `~/.claude/settings.json` | Permission rules, attribution, hooks, plugins, preferences |
| `agents/**/*.md` | `~/.claude/agents/` | Subagent definitions |
| `commands/**/*.md` | `~/.claude/commands/` | Slash commands |

Not installed: `templates/project-CLAUDE.md` (a starter for project-level CLAUDE.md files), `mcp/` (MCP setup guide), and `user_documentation/` (a docs pattern to copy into projects).

### Settings merge

The sync script merges `settings.shared.json` into each machine's `settings.json` instead of replacing it, so keys specific to one machine (`statusLine`, `voice`, `remoteControlAtStartup`, local `allow` rules) are kept.

- Objects merge key by key, arrays merge as a union, and the shared value replaces a scalar.
- The script records what it applied in `~/.claude/.claude-shit/applied-settings.json`. When an entry or key is later removed from the repo, the next sync removes it from `settings.json`, but keeps entries you added and values you changed locally.
- On Windows the rewritten `settings.json` encodes `'`, `<`, `>`, and `&` as `'`-style escapes. That's valid JSON; it's how Windows PowerShell 5.1 writes it.
- `__CLAUDE_SHIT_HOOKS__` in hook commands becomes the absolute path of the installed hooks folder.
- `settings.local.json` is never touched.

## Set up a new machine

### Windows

Requires Git for Windows, which Claude Code also uses to run hooks.

```powershell
winget install Gitleaks.Gitleaks
git clone https://github.com/redducklabs/claude-shit.git D:\repos\claude-shit
powershell -NoProfile -ExecutionPolicy Bypass -File D:\repos\claude-shit\install\sync.ps1
```

`-ExecutionPolicy Bypass` applies only to that one process. Windows client editions default to the `Restricted` policy, which refuses to run scripts; with `RemoteSigned` or a looser policy you can leave the flag out.

### Linux and WSL

WSL has its own `~/.claude`, separate from the Windows one, so run this inside each WSL distro you use Claude Code in.

```bash
sudo apt install -y jq git
mkdir -p ~/.local/bin
curl -sSfL https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz | tar -xz -C ~/.local/bin gitleaks
git clone https://github.com/redducklabs/claude-shit.git ~/repos/claude-shit
~/repos/claude-shit/install/sync.sh
```

`~/.local/bin` must be on `PATH`. On ARM machines, use the `linux_arm64` archive.

The first sync backs up every file it replaces to `~/.claude/backups/claude-shit/<timestamp>/`. Start a new Claude Code session to load the changes; run `/context` to confirm CLAUDE.md and the rules loaded, and `/status` to confirm the settings file loaded.

## Update a machine

```bash
git -C ~/repos/claude-shit pull
~/repos/claude-shit/install/sync.sh
```

On Windows:

```powershell
git -C D:\repos\claude-shit pull
powershell -NoProfile -ExecutionPolicy Bypass -File D:\repos\claude-shit\install\sync.ps1
```

Running the script again is safe: when nothing changed it prints `Up to date.` The commit last synced is in `~/.claude/.claude-shit/synced-commit`.

### Options

| bash | PowerShell | Effect |
|---|---|---|
| `--check` | `-Check` | List what would change without writing anything; exits 1 if the machine is out of date |
| `--force` | `-Force` | Overwrite or remove files that were edited locally since the last sync |
| `--target DIR` | `-Target DIR` | Use another config directory (default: `$CLAUDE_CONFIG_DIR`, else `~/.claude`) |

Exit codes: `0` success, `1` error (or pending changes with `--check`), `2` unknown option, `3` some files were skipped because they were edited locally.

## Change the configuration

1. Edit the files in this repo, not in `~/.claude`, on a branch, and open a PR. CI runs the tests on Linux and Windows.
2. After merging, update each machine as above.

If a file in `~/.claude` was edited directly (for example, Claude added a note to `CLAUDE.md`), the sync skips it, prints `SKIP <file>`, and exits 3. Move the edit into the repo and sync, or rerun with `--force` to drop it. A backup is kept either way.

## Hooks

Both hooks are bash scripts. On Windows, Claude Code runs them with Git Bash. Hook output goes straight into Claude's context, so each hook prints a short, capped message and points to a file for detail rather than relaying a tool's full output.

- **`secret-scan.sh`** runs before every `git commit` Claude makes, through either the Bash tool or (on Windows) the PowerShell tool. It scans the staged changes and the unstaged changes to tracked files with gitleaks, and blocks the commit when gitleaks finds a secret, when the scan fails, or when gitleaks isn't installed. In the last case the message gives the install command for the platform.
  - It scans unstaged changes only when the command can commit them: `-a`/`--all`, `-i`/`--include`, `-o`/`--only`, `-p`/`--patch`, `--pathspec-from-file`, a pathspec, or an argument it can't classify (a variable, for example). So a finding in a file you haven't staged doesn't block an unrelated `git commit -m ...`, or a read-only command such as `git log --grep commit`.
  - During a merge (`MERGE_HEAD` exists), a staged finding is skipped when every line of it matches the branch being merged in, because that content is already committed upstream. Conflict resolutions and other new lines are still scanned, and so is everything in a `git merge --squash`.
  - When it blocks, it prints the finding count and at most 10 findings (file, line, rule, fingerprint), under 4 KB in total. The full redacted report is kept in a per-run temp folder (`secret-scan.XXXXXXXX` under `$TMPDIR`), and the message gives its path. A scan error shows the last 10 lines of gitleaks' output and the path of the full log.
  - Because the hook runs before the whole command, it blocks a command that stages and commits in one step (`git add . && git commit ...`): the new files wouldn't be staged yet when it scans. Claude then stages and commits in separate commands.
  - It looks for gitleaks on `PATH`, then in winget's folders, `~/.local/bin`, `/usr/local/bin` and Homebrew's `/opt/homebrew/bin`. A running Claude Code app keeps the `PATH` it started with, so a fresh install would otherwise go unseen until the app restarts.
  - Claude Code also runs hooks with an `if` condition for commands it can't fully parse (variable expansions, for example). Both hooks therefore check the command text themselves. The secret scan runs whenever the command contains the word `commit` (it fails closed); the kube hook runs only for commands that call `kubectl` or `helm`. A git alias for commit, such as `git ci`, isn't detected.
  - Limitation: it scans the repository in the session's working directory, so `git -C <dir> commit` or `cd <dir> && git commit` into a different repository isn't scanned.
- **`kube-context.sh`** runs before every `kubectl` or `helm` command and tells Claude which kubectl context is active. It never blocks.

## What belongs where

| Level | Holds |
|---|---|
| `~/.claude/CLAUDE.md` (this repo) | How Claude should work in every repository: verification, security, commits, communication, delegation |
| `~/.claude/rules/` (this repo) | Personal rules for one technology, limited with `paths:` |
| `~/.claude/settings.json` (this repo) | Rules that must never be broken: deny/ask permissions, attribution, hooks |
| Project `CLAUDE.md` (committed) | Build, test, and lint commands; architecture decisions; repo conventions; gotchas. Start from `templates/project-CLAUDE.md` |
| Project `.claude/rules/` | Rules for one area of a large repo |
| `CLAUDE.local.md` (gitignored) | Personal notes for one repo: sandbox URLs, test accounts |

CLAUDE.md is guidance Claude usually follows, not enforcement. Anything that must always hold belongs in a permission rule or a hook. Keep each CLAUDE.md under about 200 lines, and use an HTML comment for notes meant only for people: Claude Code strips them before Claude sees the file.

## Software Versions

Checked 2026-10-26.

| Software | Version | Notes |
|---|---|---|
| Claude Code | 2.1.284 tested | Needs the `attribution` setting and the hook `if` field |
| gitleaks | 8.30.1 | Uses `gitleaks git --pre-commit --staged` |
| jq | 1.8.1 tested | Needed by `sync.sh`; 1.6 or later for `walk` |
| bash | 4.4 or later | `sync.sh` uses associative arrays |
| Windows PowerShell | 5.1 | `sync.ps1` |
| actions/checkout | v7 | CI |
