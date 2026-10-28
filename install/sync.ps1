<#
.SYNOPSIS
Sync this repository's Claude Code configuration into ~/.claude (Windows).
Linux, WSL, and macOS use install/sync.sh, which implements the same behavior.

.PARAMETER Check
Report what would change; write nothing; exit 1 if anything is out of date.

.PARAMETER Force
Overwrite or remove files that were edited locally since the last sync.

.PARAMETER Target
Config directory. Defaults to $env:CLAUDE_CONFIG_DIR, else ~/.claude.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Force,
    [string]$Target
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Target) {
    $Target = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
}
# Resolve relative to PowerShell's location, not .NET's current directory.
$Target = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Target)
$State = Join-Path $Target '.claude-shit'
$Manifest = Join-Path $State 'manifest.tsv'
$Applied = Join-Path $State 'applied-settings.json'
$Backup = Join-Path $Target ('backups\claude-shit\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$HooksDir = Join-Path $Target 'hooks\claude-shit'
$Utf8 = New-Object Text.UTF8Encoding $false
$script:Pending = $false
$script:Drift = $false

function Get-Sha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

function Write-Utf8([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}

function Backup-File([string]$Rel) {
    $dest = Join-Path $Backup $Rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Target $Rel) -Destination $dest -Force
}

# JSON helpers. JavaScriptSerializer parses objects into case-sensitive Dictionary
# instances (ConvertFrom-Json in Windows PowerShell 5.1 rejects keys that differ only
# by case, such as http_proxy and HTTP_PROXY) and arrays into object[].
Add-Type -AssemblyName System.Web.Extensions
$Serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Serializer.MaxJsonLength = [int]::MaxValue

function Get-EmptyMap { New-Object 'System.Collections.Generic.Dictionary[string,object]' }

function ConvertFrom-JsonText([string]$Text, [string]$Source) {
    if (-not $Text.Trim()) { return , (Get-EmptyMap) }
    try { $parsed = $Serializer.DeserializeObject($Text) }
    catch { throw "$Source is not valid JSON; fix it before syncing. $($_.Exception.Message)" }
    if ($parsed -isnot [System.Collections.IDictionary]) { throw "$Source must contain a JSON object." }
    return , $parsed
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return , (Get-EmptyMap) }
    return , (ConvertFrom-JsonText ([IO.File]::ReadAllText($Path)) $Path)
}

function ConvertTo-JsonText($Value, [switch]$Compress) {
    if ($Compress) { return ConvertTo-Json -InputObject $Value -Depth 50 -Compress }
    return ConvertTo-Json -InputObject $Value -Depth 50
}

function Test-IsMap($v) { $v -is [System.Collections.IDictionary] }
function Test-IsList($v) { $v -is [object[]] }

# Key order doesn't matter for equality (jq's == ignores it too), so compare JSON
# serialized with keys sorted ordinally.
function ConvertTo-Canonical($Value) {
    if (Test-IsMap $Value) {
        $sorted = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
        foreach ($k in $Value.Keys) { $sorted[$k] = ConvertTo-Canonical $Value[$k] }
        return , $sorted
    }
    if (Test-IsList $Value) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($x in $Value) { $list.Add((ConvertTo-Canonical $x)) }
        return , $list.ToArray()
    }
    return $Value
}

function Test-JsonEqual($A, $B) {
    (ConvertTo-JsonText (ConvertTo-Canonical $A) -Compress) -ceq (ConvertTo-JsonText (ConvertTo-Canonical $B) -Compress)
}

function Test-ListHasItem([object[]]$List, $Item) {
    foreach ($x in $List) { if (Test-JsonEqual $x $Item) { return $true } }
    return $false
}

# Remove what an earlier sync added ($Prev) that the repo no longer has ($New), keeping
# anything added or changed locally. $New is $null under a key the repo dropped.
function Get-PrunedJson($Cur, $Prev, $New) {
    if ((Test-IsMap $Cur) -and (Test-IsMap $Prev)) {
        foreach ($k in @($Prev.Keys)) {
            if (-not $Cur.ContainsKey($k)) { continue }
            if ((Test-IsMap $New) -and $New.ContainsKey($k)) {
                $Cur[$k] = Get-PrunedJson $Cur[$k] $Prev[$k] $New[$k]
                continue
            }
            $v = Get-PrunedJson $Cur[$k] $Prev[$k] $null
            $emptied = ((Test-IsMap $v) -and (Test-IsMap $Prev[$k]) -and $v.Count -eq 0) -or
                       ((Test-IsList $v) -and (Test-IsList $Prev[$k]) -and $v.Count -eq 0)
            if ($emptied -or (Test-JsonEqual $v $Prev[$k])) { [void]$Cur.Remove($k) } else { $Cur[$k] = $v }
        }
        return , $Cur
    }
    if ((Test-IsList $Cur) -and (Test-IsList $Prev)) {
        $kept = New-Object System.Collections.Generic.List[object]
        foreach ($x in $Cur) {
            if (-not (Test-ListHasItem $Prev $x) -or ((Test-IsList $New) -and (Test-ListHasItem $New $x))) { $kept.Add($x) }
        }
        return , $kept.ToArray()
    }
    return , $Cur
}

function Merge-Json($Cur, $New) {
    if ((Test-IsMap $Cur) -and (Test-IsMap $New)) {
        foreach ($k in @($New.Keys)) {
            if ($Cur.ContainsKey($k)) { $Cur[$k] = Merge-Json $Cur[$k] $New[$k] } else { $Cur[$k] = $New[$k] }
        }
        return , $Cur
    }
    if ((Test-IsList $Cur) -and (Test-IsList $New)) {
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($x in $Cur) { $out.Add($x) }
        foreach ($x in $New) { if (-not (Test-ListHasItem $out.ToArray() $x)) { $out.Add($x) } }
        return , $out.ToArray()
    }
    return , $New
}

# Previous manifest: "<relative dest>`t<sha256 at last sync>"
$Old = @{}
if (Test-Path -LiteralPath $Manifest) {
    foreach ($line in [IO.File]::ReadAllLines($Manifest)) {
        $parts = $line -split "`t"
        if ($parts.Count -eq 2 -and $parts[0]) { $Old[$parts[0]] = $parts[1] }
    }
}
$New = @{}

# Source file -> destination, both relative with forward slashes.
$map = New-Object System.Collections.Generic.List[object]
$map.Add(@('claude_md/CLAUDE.md', 'CLAUDE.md'))
foreach ($dir in 'rules', 'commands', 'agents') {
    $root = Join-Path $Repo $dir
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($Repo.Length + 1) -replace '\\', '/'
        $map.Add(@($rel, $rel))
    }
}
Get-ChildItem -LiteralPath (Join-Path $Repo 'hooks') -Recurse -File -Filter '*.sh' | Sort-Object FullName | ForEach-Object {
    $rel = $_.FullName.Substring($Repo.Length + 1) -replace '\\', '/'
    $map.Add(@($rel, ('hooks/claude-shit/' + $rel.Substring('hooks/'.Length))))
}

foreach ($pair in $map) {
    $src = Join-Path $Repo $pair[0]
    $rel = $pair[1]
    $dest = Join-Path $Target $rel
    $want = Get-Sha $src
    if (Test-Path -LiteralPath $dest) {
        $have = Get-Sha $dest
        if ($have -eq $want) { $New[$rel] = $want; continue }
        if ($Old.ContainsKey($rel) -and $Old[$rel] -ne $have -and -not $Force) {
            Write-Output "SKIP    $rel (edited locally since the last sync; port the edit to the repo or rerun with -Force)"
            $New[$rel] = $Old[$rel]
            $script:Drift = $true
            continue
        }
        $script:Pending = $true
        Write-Output "UPDATE  $rel"
        if (-not $Check) { Backup-File $rel; Copy-Item -LiteralPath $src -Destination $dest -Force }
    }
    else {
        $script:Pending = $true
        Write-Output "ADD     $rel"
        if (-not $Check) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            Copy-Item -LiteralPath $src -Destination $dest
        }
    }
    $New[$rel] = $want
}

# Files this repo installed before but no longer ships.
foreach ($rel in @($Old.Keys | Sort-Object)) {
    if ($New.ContainsKey($rel)) { continue }
    $dest = Join-Path $Target $rel
    if (-not (Test-Path -LiteralPath $dest)) { continue }
    if ((Get-Sha $dest) -ne $Old[$rel] -and -not $Force) {
        Write-Output "KEEP    $rel (removed from the repo but edited locally; delete it yourself or rerun with -Force)"
        $script:Drift = $true
        continue
    }
    $script:Pending = $true
    Write-Output "REMOVE  $rel"
    if (-not $Check) { Backup-File $rel; Remove-Item -LiteralPath $dest }
}

# settings.json: drop entries an earlier sync added that the repo no longer has, then
# merge the shared settings in. Objects merge by key, arrays by union, scalars are replaced.
$hooksPath = $HooksDir -replace '\\', '/'
$sharedText = [IO.File]::ReadAllText((Join-Path $Repo 'settings\settings.shared.json')).Replace('__CLAUDE_SHIT_HOOKS__', $hooksPath)
$shared = ConvertFrom-JsonText $sharedText 'settings\settings.shared.json'
$settingsPath = Join-Path $Target 'settings.json'
$current = Read-Json $settingsPath
$before = ConvertTo-JsonText $current
$previous = Read-Json $Applied
$merged = Merge-Json (Get-PrunedJson $current $previous $shared) $shared
$after = ConvertTo-JsonText $merged
if ($after -ne $before) {
    $script:Pending = $true
    Write-Output 'UPDATE  settings.json'
    if (-not $Check) {
        if (Test-Path -LiteralPath $settingsPath) { Backup-File 'settings.json' }
        Write-Utf8 $settingsPath ($after + "`n")
    }
}

if (-not $Check) {
    $lines = @($New.Keys | Sort-Object | ForEach-Object { "$_`t$($New[$_])" })
    Write-Utf8 $Manifest (($lines -join "`n") + "`n")
    Write-Utf8 $Applied ((ConvertTo-JsonText $shared) + "`n")
    $commit = 'unknown'
    if (Get-Command git -ErrorAction SilentlyContinue) {
        # Windows PowerShell turns native stderr into a terminating error under 'Stop'.
        $ErrorActionPreference = 'Continue'
        $rev = & git -C $Repo rev-parse HEAD 2>$null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -eq 0 -and $rev) { $commit = $rev }
    }
    Write-Utf8 (Join-Path $State 'synced-commit') ($commit + "`n")
    if (Test-Path -LiteralPath $Backup) { Write-Output "Backups of replaced files: $Backup" }
}

# Same places the secret-scan hook looks: PATH, then winget's folders (a running app
# keeps its old PATH, so a fresh install may only be found there).
$wingetGitleaks = @()
if ($env:LOCALAPPDATA) {
    $wingetGitleaks = @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\gitleaks.exe'), (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Gitleaks.Gitleaks_*\gitleaks.exe') -ErrorAction SilentlyContinue)
}
if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue) -and $wingetGitleaks.Count -eq 0) {
    Write-Output 'WARN    gitleaks not found. The secret-scan hook blocks every git commit until it is installed (winget install Gitleaks.Gitleaks).'
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Output 'WARN    kubectl not found. The kube-context hook will report it missing.'
}
$gitBash = Join-Path ${env:ProgramFiles} 'Git\bin\bash.exe'
if (-not (Test-Path -LiteralPath $gitBash) -and -not $env:CLAUDE_CODE_GIT_BASH_PATH) {
    Write-Output 'WARN    Git Bash not found. The hooks are bash scripts and need Git for Windows.'
}

if (-not $script:Pending -and -not $script:Drift) { Write-Output 'Up to date.' }
elseif ($Check -and $script:Pending) { exit 1 }
if ($script:Drift) { exit 3 }
exit 0
