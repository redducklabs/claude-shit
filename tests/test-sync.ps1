# Tests for install/sync.ps1 against a throwaway config directory.
# Also checks that sync.ps1 and sync.sh produce the same settings.json when bash and jq exist.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Passes = 0
$script:Fails = 0
function Pass([string]$Name) { $script:Passes++; Write-Output "ok    $Name" }
function Fail([string]$Name, [string]$Detail) { $script:Fails++; Write-Output "FAIL  $Name"; Write-Output "      $Detail" }
function Assert-Eq([string]$Name, $Expected, $Actual) {
    if ("$Expected" -ceq "$Actual") { Pass $Name } else { Fail $Name "expected [$Expected], got [$Actual]" }
}
function Assert-True([string]$Name, [bool]$Cond, [string]$Detail = '') { if ($Cond) { Pass $Name } else { Fail $Name $Detail } }

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('claude-shit-test-' + [Guid]::NewGuid().ToString('N'))
$Repo = Join-Path $Tmp 'repo'
$Target = Join-Path $Tmp 'claude'
New-Item -ItemType Directory -Path $Repo, $Target -Force | Out-Null
foreach ($d in 'claude_md', 'rules', 'commands', 'hooks', 'agents', 'settings', 'install') {
    Copy-Item -Recurse -LiteralPath (Join-Path $RepoRoot $d) -Destination $Repo
}

$initialSettings = @'
{
  "statusLine": {"type": "command", "command": "status.ps1 'quoted'"},
  "permissions": {"deny": ["Bash(rm -rf *)"], "allow": ["Bash(ls *)"]},
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "notify.sh"}]}]},
  "effortLevel": "low"
}
'@
$utf8 = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $Target 'settings.json'), $initialSettings, $utf8)

function Invoke-Sync([string[]]$Extra = @(), [string]$To = $Target) {
    $argList = @('-NoProfile', '-File', (Join-Path $Repo 'install\sync.ps1'), '-Target', $To) + $Extra
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe @argList 2>&1 | Out-String
    return @{ Out = $out; Rc = $LASTEXITCODE }
}
function Get-Settings { [IO.File]::ReadAllText((Join-Path $Target 'settings.json')) | ConvertFrom-Json }

try {
    # Fresh install
    $r = Invoke-Sync
    Assert-Eq 'fresh install exits 0' 0 $r.Rc
    foreach ($f in 'CLAUDE.md', 'rules\github-actions.md', 'commands\create-pr.md', 'hooks\claude-shit\secret-scan.sh', 'agents\core\debugger.md', '.claude-shit\manifest.tsv') {
        Assert-True "installed $f" (Test-Path -LiteralPath (Join-Path $Target $f))
    }
    $s = Get-Settings
    Assert-Eq 'local scalar kept' "status.ps1 'quoted'" $s.statusLine.command
    Assert-Eq 'shared scalar replaces local' 'xhigh' $s.effortLevel
    Assert-True 'local deny entry kept' ($s.permissions.deny -contains 'Bash(rm -rf *)')
    Assert-True 'shared deny entry added' ($s.permissions.deny -contains 'Bash(helm install *)')
    Assert-Eq 'single-element allow stays an array' '["Bash(ls *)"]' (ConvertTo-Json -InputObject @($s.permissions.allow) -Compress)
    Assert-Eq 'local Stop hook kept' 1 @($s.hooks.Stop).Count
    Assert-Eq 'attribution commit empty' '' $s.attribution.commit
    $cmd = $s.hooks.PreToolUse[0].hooks[0].command
    Assert-True 'hook placeholder replaced' (-not $cmd.Contains('__CLAUDE_SHIT_HOOKS__')) $cmd
    Assert-True 'hook path uses forward slashes' ($cmd -match '[A-Za-z]:/.*/hooks/claude-shit/secret-scan\.sh') $cmd
    $raw = [IO.File]::ReadAllBytes((Join-Path $Target 'settings.json'))
    Assert-True 'settings.json has no BOM' (-not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB))

    # Second run is a no-op
    $r = Invoke-Sync
    Assert-Eq 'rerun exits 0' 0 $r.Rc
    Assert-True 'rerun reports up to date' ($r.Out -match 'Up to date\.') $r.Out
    Assert-Eq 'rerun adds no duplicate hooks' 1 @((Get-Settings).hooks.PreToolUse).Count

    # -Check writes nothing and exits 1 when out of date
    Add-Content -LiteralPath (Join-Path $Repo 'claude_md\CLAUDE.md') -Value '- extra rule'
    $before = [IO.File]::ReadAllText((Join-Path $Target 'CLAUDE.md'))
    $r = Invoke-Sync @('-Check')
    Assert-Eq 'check exits 1 when pending' 1 $r.Rc
    Assert-True 'check lists the update' ($r.Out -match 'UPDATE  CLAUDE\.md') $r.Out
    Assert-Eq 'check leaves file untouched' $before ([IO.File]::ReadAllText((Join-Path $Target 'CLAUDE.md')))

    # Update propagates, with a backup
    $r = Invoke-Sync
    Assert-Eq 'update exits 0' 0 $r.Rc
    Assert-True 'updated CLAUDE.md has new line' ([IO.File]::ReadAllText((Join-Path $Target 'CLAUDE.md')).Contains('extra rule'))
    Assert-Eq 'backup created' 1 @(Get-ChildItem -Recurse -LiteralPath (Join-Path $Target 'backups\claude-shit') -Filter CLAUDE.md).Count

    # Removing things from the repo removes them locally, but only what the repo added
    Remove-Item -LiteralPath (Join-Path $Repo 'rules\github-actions.md')
    $sharedPath = Join-Path $Repo 'settings\settings.shared.json'
    $sharedText = [IO.File]::ReadAllText($sharedPath).Replace("`"Bash(helm install *)`",", '')
    [IO.File]::WriteAllText($sharedPath, $sharedText, $utf8)
    $r = Invoke-Sync
    Assert-Eq 'removal sync exits 0' 0 $r.Rc
    Assert-True 'removed rule deleted' (-not (Test-Path -LiteralPath (Join-Path $Target 'rules\github-actions.md')))
    $s = Get-Settings
    Assert-True 'removed deny entry dropped' (-not ($s.permissions.deny -contains 'Bash(helm install *)'))
    Assert-True 'local deny entry survives removal' ($s.permissions.deny -contains 'Bash(rm -rf *)')

    # A locally edited file is not overwritten without -Force
    Add-Content -LiteralPath (Join-Path $Target 'CLAUDE.md') -Value 'local note'
    Add-Content -LiteralPath (Join-Path $Repo 'claude_md\CLAUDE.md') -Value '- another rule'
    $r = Invoke-Sync
    Assert-Eq 'drift exits 3' 3 $r.Rc
    Assert-True 'drift reported' ($r.Out -match 'SKIP    CLAUDE\.md') $r.Out
    Assert-True 'local edit kept' ([IO.File]::ReadAllText((Join-Path $Target 'CLAUDE.md')).Contains('local note'))
    $r = Invoke-Sync @('-Force')
    Assert-Eq 'force exits 0' 0 $r.Rc
    $text = [IO.File]::ReadAllText((Join-Path $Target 'CLAUDE.md'))
    Assert-True 'force overwrites local edit' (-not $text.Contains('local note'))
    Assert-True 'force installs repo version' ($text.Contains('another rule'))

    # Invalid settings.json is left alone
    [IO.File]::WriteAllText((Join-Path $Target 'settings.json'), '{ not json', $utf8)
    $r = Invoke-Sync
    Assert-True 'invalid settings fails' ($r.Rc -ne 0) "rc=$($r.Rc)"
    Assert-Eq 'invalid settings untouched' '{ not json' ([IO.File]::ReadAllText((Join-Path $Target 'settings.json')))

    # Parity: both implementations produce the same settings from the same input
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    $jq = Get-Command jq -ErrorAction SilentlyContinue
    if ($bash -and $jq) {
        $a = Join-Path $Tmp 'parity-ps'
        $b = Join-Path $Tmp 'parity-sh'
        foreach ($t in $a, $b) {
            New-Item -ItemType Directory -Path $t -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $t 'settings.json'), $initialSettings, $utf8)
        }
        $null = Invoke-Sync @() $a
        $shTarget = (& bash -c 'cygpath -u "$1"' _ $b).Trim()
        $shScript = (& bash -c 'cygpath -u "$1"' _ (Join-Path $Repo 'install\sync.sh')).Trim()
        $ErrorActionPreference = 'Continue'
        $null = & bash $shScript --target $shTarget 2>&1
        $ErrorActionPreference = 'Stop'
        $canon = { param($p) (& jq -S -c . $p) -join '' }
        Assert-Eq 'sync.ps1 and sync.sh produce identical settings' (& $canon (Join-Path $b 'settings.json')) (& $canon (Join-Path $a 'settings.json'))
    }
    else {
        Write-Output 'skip  parity check (bash or jq not found)'
    }
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $Tmp -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output "$script:Passes passed, $script:Fails failed"
if ($script:Fails -gt 0) { exit 1 }
exit 0
