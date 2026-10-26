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
$Target = [IO.Path]::GetFullPath($Target)
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

# JSON helpers. Windows PowerShell 5.1 has no -AsHashtable, so convert parsed JSON to
# ordered dictionaries and object[] arrays, which ConvertTo-Json serializes faithfully.
function ConvertTo-Plain($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = ConvertTo-Plain $p.Value }
        return $o
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) { $list.Add((ConvertTo-Plain $item)) }
        return , $list.ToArray()
    }
    return $Value
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [ordered]@{} }
    $text = [IO.File]::ReadAllText($Path)
    if (-not $text.Trim()) { return [ordered]@{} }
    try { $parsed = $text | ConvertFrom-Json }
    catch { throw "$Path is not valid JSON; fix it before syncing. $($_.Exception.Message)" }
    return ConvertTo-Plain $parsed
}

function ConvertTo-JsonText($Value, [switch]$Compress) {
    if ($Compress) { return ConvertTo-Json -InputObject $Value -Depth 50 -Compress }
    return ConvertTo-Json -InputObject $Value -Depth 50
}

function Test-IsMap($v) { $v -is [System.Collections.IDictionary] }
function Test-IsList($v) { $v -is [object[]] }

function Test-Contains([object[]]$List, $Item) {
    $key = ConvertTo-JsonText $Item -Compress
    foreach ($x in $List) { if ((ConvertTo-JsonText $x -Compress) -eq $key) { return $true } }
    return $false
}

# Remove what an earlier sync added ($Prev) that the repo no longer has ($New).
function Get-PrunedJson($Cur, $Prev, $New) {
    if ((Test-IsMap $Cur) -and (Test-IsMap $Prev)) {
        foreach ($k in @($Prev.Keys)) {
            if ((Test-IsMap $New) -and $New.Contains($k)) {
                if ($Cur.Contains($k)) { $Cur[$k] = Get-PrunedJson $Cur[$k] $Prev[$k] $New[$k] }
            }
            elseif ($Cur.Contains($k)) { $Cur.Remove($k) }
        }
        return $Cur
    }
    if ((Test-IsList $Cur) -and (Test-IsList $Prev)) {
        $kept = New-Object System.Collections.Generic.List[object]
        foreach ($x in $Cur) {
            if (-not (Test-Contains $Prev $x) -or ((Test-IsList $New) -and (Test-Contains $New $x))) { $kept.Add($x) }
        }
        return , $kept.ToArray()
    }
    return , $Cur
}

function Merge-Json($Cur, $New) {
    if ((Test-IsMap $Cur) -and (Test-IsMap $New)) {
        foreach ($k in @($New.Keys)) {
            if ($Cur.Contains($k)) { $Cur[$k] = Merge-Json $Cur[$k] $New[$k] } else { $Cur[$k] = $New[$k] }
        }
        return $Cur
    }
    if ((Test-IsList $Cur) -and (Test-IsList $New)) {
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($x in $Cur) { $out.Add($x) }
        foreach ($x in $New) { if (-not (Test-Contains $out.ToArray() $x)) { $out.Add($x) } }
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
$shared = ConvertTo-Plain ($sharedText | ConvertFrom-Json)
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

if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
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
