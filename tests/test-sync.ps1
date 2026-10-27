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
function Read-SettingsFile { [IO.File]::ReadAllText((Join-Path $Target 'settings.json')) | ConvertFrom-Json }

try {
    # Fresh install
    $r = Invoke-Sync
    Assert-Eq 'fresh install exits 0' 0 $r.Rc
    foreach ($f in 'CLAUDE.md', 'rules\github-actions.md', 'commands\create-pr.md', 'hooks\claude-shit\secret-scan.sh', 'agents\core\debugger.md', '.claude-shit\manifest.tsv') {
        Assert-True "installed $f" (Test-Path -LiteralPath (Join-Path $Target $f))
    }
    $s = Read-SettingsFile
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
    Assert-Eq 'rerun adds no duplicate hooks' 1 @((Read-SettingsFile).hooks.PreToolUse).Count

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
    $s = Read-SettingsFile
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

    # Keys the repo stops shipping: local additions and changes survive, untouched values go
    $settingsFile = Join-Path $Target 'settings.json'
    $text = [IO.File]::ReadAllText($settingsFile)
    $text = $text -replace '"ask":\s*\[', '"ask": ["Bash(rm -rf *)",' -replace '"effortLevel":\s*"xhigh"', '"effortLevel": "medium"'
    [IO.File]::WriteAllText($settingsFile, $text, $utf8)
    $shared = [IO.File]::ReadAllText($sharedPath)
    $shared = $shared -replace '(?s)"ask":\s*\[.*?\],?', '' -replace '"effortLevel":\s*"xhigh",', '' -replace '"outputStyle":\s*"Concise",', ''
    $shared = $shared -replace '\],(\s*)\}', ']$1}'
    [IO.File]::WriteAllText($sharedPath, $shared, $utf8)
    $r = Invoke-Sync
    Assert-Eq 'dropped-key sync exits 0' 0 $r.Rc
    $s = Read-SettingsFile
    Assert-Eq 'local ask entry kept after repo drops ask' '["Bash(rm -rf *)"]' (ConvertTo-Json -InputObject @($s.permissions.ask) -Compress)
    Assert-Eq 'locally changed scalar kept after repo drops it' 'medium' $s.effortLevel
    Assert-True 'untouched scalar removed with the repo key' (-not ($s.PSObject.Properties.Name -contains 'outputStyle'))

    # A missing source directory doesn't remove files from the other directories
    Remove-Item -Recurse -Force -LiteralPath (Join-Path $Repo 'rules'), (Join-Path $Repo 'commands')
    $r = Invoke-Sync
    Assert-Eq 'sync without rules/commands exits 0' 0 $r.Rc
    Assert-True 'hooks kept when rules/ is missing' (Test-Path -LiteralPath (Join-Path $Target 'hooks\claude-shit\secret-scan.sh'))
    Assert-True 'agents kept when rules/ is missing' (Test-Path -LiteralPath (Join-Path $Target 'agents\core\debugger.md'))
    Assert-True 'commands removed with their directory' (-not (Test-Path -LiteralPath (Join-Path $Target 'commands\create-pr.md')))

    # Key order inside an array entry doesn't create duplicates
    $s = Read-SettingsFile
    $entry = $s.hooks.PreToolUse[0]
    $reordered = [ordered]@{ hooks = $entry.hooks; matcher = $entry.matcher }
    $s.hooks.PreToolUse = @($reordered)
    [IO.File]::WriteAllText($settingsFile, (ConvertTo-Json -InputObject $s -Depth 50), $utf8)
    $null = Invoke-Sync
    Assert-Eq 'reordered hook entry not duplicated' 1 @((Read-SettingsFile).hooks.PreToolUse).Count

    # Keys that differ only by case are kept apart
    $raw = [IO.File]::ReadAllText($settingsFile)
    $raw = $raw -replace '"env":\s*\{', '"env": {"http_proxy": "http://a", "HTTP_PROXY": "http://b",'
    [IO.File]::WriteAllText($settingsFile, $raw, $utf8)
    $r = Invoke-Sync
    Assert-Eq 'case-differing keys sync' 0 $r.Rc
    $raw = [IO.File]::ReadAllText($settingsFile)
    Assert-True 'both case variants kept' ($raw.Contains('"http_proxy"') -and $raw.Contains('"HTTP_PROXY"')) $raw

    # An empty settings.json is treated as {}
    [IO.File]::WriteAllText($settingsFile, '', $utf8)
    $r = Invoke-Sync
    Assert-Eq 'empty settings.json syncs' 0 $r.Rc
    Assert-Eq 'empty settings.json gets shared keys' '' (Read-SettingsFile).attribution.pr

    # A relative -Target resolves against the current PowerShell location
    # PowerShell starts the child powershell.exe in the current location.
    Push-Location -LiteralPath $Tmp
    try { $r = Invoke-Sync @() 'rel-claude' } finally { Pop-Location }
    Assert-Eq 'relative target exits 0' 0 $r.Rc
    Assert-True 'relative target lands under the current location' (Test-Path -LiteralPath (Join-Path $Tmp 'rel-claude\settings.json'))

    # Invalid settings.json is left alone
    [IO.File]::WriteAllText((Join-Path $Target 'settings.json'), '{ not json', $utf8)
    $r = Invoke-Sync
    Assert-True 'invalid settings fails' ($r.Rc -ne 0) "rc=$($r.Rc)"
    Assert-Eq 'invalid settings untouched' '{ not json' ([IO.File]::ReadAllText((Join-Path $Target 'settings.json')))

    # Parity: both implementations produce the same settings from the same input
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    $hasJq = $false
    if ($bash) { $null = '' | & bash -c 'command -v jq' 2>&1; $hasJq = ($LASTEXITCODE -eq 0) }
    if ($bash -and $hasJq) {
        $a = Join-Path $Tmp 'parity-ps'
        $b = Join-Path $Tmp 'parity-sh'
        foreach ($t in $a, $b) {
            New-Item -ItemType Directory -Path $t -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $t 'settings.json'), $initialSettings, $utf8)
        }
        $null = Invoke-Sync @() $a
        # Git Bash accepts C:/ paths. Empty stdin: a bash started from PowerShell inside
        # another Git Bash can otherwise block waiting on the inherited console.
        $shTarget = $b -replace '\\', '/'
        $shScript = (Join-Path $Repo 'install\sync.sh') -replace '\\', '/'
        $ErrorActionPreference = 'Continue'
        $null = '' | & bash $shScript --target $shTarget 2>&1
        $ErrorActionPreference = 'Stop'
        # Each target embeds its own path in the hook commands; normalize that part.
        # Run jq through bash: it finds the same jq sync.sh uses, including one installed
        # without an .exe extension, which PowerShell can't start directly.
        $canon = { param($p) (('' | & bash -c 'jq -S -c . "$1"' _ ($p -replace '\\', '/')) -join '') -replace 'parity-(ps|sh)', 'parity-X' }
        $fromSh = & $canon (Join-Path $b 'settings.json')
        $fromPs = & $canon (Join-Path $a 'settings.json')
        Assert-True 'parity outputs are non-empty JSON' ($fromSh.StartsWith('{') -and $fromPs.StartsWith('{')) "sh=[$fromSh] ps=[$fromPs]"
        Assert-True 'parity output contains the shared hooks' ($fromSh.Contains('parity-X/hooks/claude-shit/secret-scan.sh')) $fromSh
        Assert-Eq 'sync.ps1 and sync.sh produce identical settings' $fromSh $fromPs
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
