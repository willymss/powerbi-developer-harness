<#
.SYNOPSIS
  Probe the Power BI developer toolchain (probes run in parallel, <= 4 s each). Never fails.
.DESCRIPTION
  Reports pbir, uv, node/npm/npx, powerbi-desktop, powerbi-report-author, te (with
  preview expiry), fab, az, jq, git, Windows PowerShell 5.1 (TOM host), ADOMD, and whether
  the powerbi-modeling-mcp npx cache is primed. Output: [{tool, present, version, path, note}].
.PARAMETER Fast
  Skip slow probes (powerbi-report-author doctor, pbir update check).
.PARAMETER Save
  Also write the table to this JSON file (SessionStart writes tool-status.json).
#>
[CmdletBinding()]
param([switch]$Fast, [switch]$Json, [string]$Save = '')
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
foreach ($d in @("$env:LOCALAPPDATA\Programs\te", "$env:APPDATA\npm", "$env:USERPROFILE\.local\bin")) {
    if ($d -and (Test-Path -LiteralPath $d) -and (($env:Path -split ';') -notcontains $d)) { $env:Path = "$env:Path;$d" }
}

function Get-Exe([string]$Name) {
    # Prefer .exe, then .cmd/.bat (npm shims), never a .ps1 shim.
    try {
        $all = @(Get-Command $Name -CommandType Application -ErrorAction Stop | ForEach-Object { $_.Source })
        $pick = $all | Where-Object { $_ -match '\.exe$' } | Select-Object -First 1
        if (-not $pick) { $pick = $all | Where-Object { $_ -match '\.(cmd|bat)$' } | Select-Object -First 1 }
        if (-not $pick) { $pick = $all | Where-Object { $_ -notmatch '\.ps1$' } | Select-Object -First 1 }
        return $pick
    } catch { return $null }
}
function Start-Probe([string]$Tool, [string]$ArgList) {
    $exe = Get-Exe $Tool
    if (-not $exe) { return $null }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if ($exe -match '\.(cmd|bat)$') { $psi.FileName = "$env:ComSpec"; $psi.Arguments = "/d /c `"`"$exe`" $ArgList`"" }
        else { $psi.FileName = $exe; $psi.Arguments = $ArgList }
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        try { $p.StandardInput.Close() } catch {}
        return [ordered]@{ exe = $exe; proc = $p; out = $p.StandardOutput.ReadToEndAsync(); err = $p.StandardError.ReadToEndAsync() }
    } catch { return [ordered]@{ exe = $exe; proc = $null; out = $null; err = $null } }
}
function Wait-Probe($h, [int]$Timeout = 4) {
    $r = [ordered]@{ exe = ''; stdout = ''; stderr = ''; timed_out = $false; ok = $false }
    if (-not $h) { return $r }
    $r.exe = $h.exe
    if (-not $h.proc) { return $r }
    try {
        if (-not $h.proc.WaitForExit($Timeout * 1000)) { $r.timed_out = $true; try { $h.proc.Kill($true) } catch {} }
        try { $r.stdout = $h.out.GetAwaiter().GetResult() } catch {}
        try { $r.stderr = $h.err.GetAwaiter().GetResult() } catch {}
        $r.ok = (-not $r.timed_out) -and ($h.proc.ExitCode -eq 0)
    } catch {}
    return $r
}
function Row([string]$Tool, [bool]$Present, [string]$Version = '', [string]$Path = '', [string]$Note = '') {
    [ordered]@{ tool = $Tool; present = $Present; version = $Version; path = $Path; note = $Note }
}

# ---- start every probe at once ----
$defs = @(
    @{ tool = 'pbir'; args = '-q --version'; rx = '(\d+\.\d+\.\d+)' },
    @{ tool = 'uv'; args = '--version'; rx = '(\d+\.\d+\.\d+)' },
    @{ tool = 'node'; args = '--version'; rx = '(\d+\.\d+\.\d+)' },
    @{ tool = 'npm'; args = '--version'; rx = '(\d+\.\d+\.\d+)' },
    @{ tool = 'npx'; args = '--version'; rx = '(\d+\.\d+\.\d+)' },
    @{ tool = 'powerbi-desktop'; args = '--version'; rx = '(\d+\.\d+\.\d+)' },
    @{ tool = 'powerbi-report-author'; args = '--version'; rx = '(\d+\.\d+\.\d+)' },
    @{ tool = 'te'; args = '--version'; rx = '(?m)^\s*(\d+\.\d+\.\d+[\.\d]*)\s*$' },
    @{ tool = 'fab'; args = '--version'; rx = '(\d+\.\d+\.\d+)' },
    @{ tool = 'az'; args = 'version'; rx = '"azure-cli":\s*"(\d+\.\d+\.\d+)"' },
    @{ tool = 'jq'; args = '--version'; rx = 'jq-(\d+\.\d+[\.\d]*)' },
    @{ tool = 'git'; args = '--version'; rx = '(\d+\.\d+\.\d+)' }
)
$handles = @{}
foreach ($d in $defs) { $handles[$d.tool] = Start-Probe $d.tool $d.args }
$doctor = $null
if (-not $Fast -and (Get-Exe 'powerbi-report-author')) { $doctor = Start-Probe 'powerbi-report-author' 'doctor' }
$pbirFull = $null
if (-not $Fast -and (Get-Exe 'pbir')) { $pbirFull = Start-Probe 'pbir' '--version' }

$rows = @()
$results = @{}
foreach ($d in $defs) {
    $h = $handles[$d.tool]
    if (-not $h) { $rows += Row $d.tool $false; continue }
    $r = Wait-Probe $h 4
    $results[$d.tool] = $r
    $txt = $r.stdout + "`n" + $r.stderr
    $v = ''
    if ($txt -match $d.rx) { $v = $matches[1] }
    $note = if ($r.timed_out) { 'probe timed out' } else { '' }
    $rows += Row $d.tool $true $v $r.exe $note
}
function Get-Row([string]$t) { $rows | Where-Object { $_.tool -eq $t } | Select-Object -First 1 }

# node-dependent tools: explain absence
$node = Get-Row 'node'
if (-not $node.present) {
    foreach ($t in 'npm', 'npx', 'powerbi-desktop', 'powerbi-report-author') { $x = Get-Row $t; if ($x -and -not $x.present) { $x.note = 'unavailable (Node absent - removed by device management?)' } }
}
# pbir update banner (slow path)
if ($pbirFull) {
    $r = Wait-Probe $pbirFull 8
    $txt = $r.stdout + $r.stderr
    if ($txt -match '(?i)(\d+\.\d+\.\d+)[^\n]*available' -or $txt -match '(?i)available[^\n]*?(\d+\.\d+\.\d+)') { (Get-Row 'pbir').note = "update available: $($matches[1]) (uv tool upgrade pbir-cli)" }
}
# te expiry
$te = Get-Row 'te'
if ($te.present) {
    $txt = $results['te'].stdout + $results['te'].stderr
    if ($txt -match '(?i)expires in (\d+) day\(s\), on (\d{4}-\d{2}-\d{2})') {
        $days = [int]$matches[1]; $date = $matches[2]
        $te.note = "preview expires $date ($days days)"
        if ($days -le 10) { $te.note = "WARNING: te preview expires $date ($days days) - update from https://tabulareditor.com/downloads" }
    }
    if ($txt -match '(?i)has expired|expired on') { $te.present = $false; $te.note = 'preview EXPIRED - update from https://tabulareditor.com/downloads' }
}
# doctor
if ($doctor) {
    $r = Wait-Probe $doctor 10
    $ok = $r.stdout -match '"ok":\s*true'
    $rows += Row 'powerbi-report-author doctor' $ok '' '' ($(if ($ok) { 'environment ok' } else { 'doctor reported problems' }))
}
# Windows PowerShell 5.1 (only host that loads TOM/ADOMD net45 assemblies)
$ps5 = Get-Exe 'powershell.exe'
$rows += Row 'powershell 5.1' ([bool]$ps5) ($(if ($ps5) { '5.1' } else { '' })) ($(if ($ps5) { $ps5 } else { '' })) 'required for TOM (connect-pbid); pwsh cannot load TOM'
# ADOMD
$adomd = ''
$cands = @()
if ($env:PBIR_ADOMD_DIR) { $cands += $env:PBIR_ADOMD_DIR }
$cands += "$env:TEMP\tom_nuget"; $cands += "$env:ProgramFiles\DAX Studio"; $cands += "${env:ProgramFiles(x86)}\DAX Studio"
foreach ($c in $cands) {
    if ($c -and (Test-Path -LiteralPath $c)) {
        $hit = Get-ChildItem -LiteralPath $c -Filter 'Microsoft.AnalysisServices.AdomdClient.dll' -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $adomd = $hit.DirectoryName; break }
    }
}
$rows += Row 'adomd' ([bool]$adomd) '' $adomd ($(if ($adomd) { 'set PBIR_ADOMD_DIR for thick-report pbir model -q' } else { 'thick-report pbir model -q unavailable; use te query or TOM' }))
# MCP primed?
$primed = $false; $primedPath = ''
try {
    $npx = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
    if (Test-Path -LiteralPath $npx) {
        $hit = Get-ChildItem -LiteralPath $npx -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'node_modules\@microsoft\powerbi-modeling-mcp' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($hit) { $primed = $true; $primedPath = $hit }
    }
} catch {}
$rows += Row 'powerbi-modeling-mcp (npx cache)' $primed '' $primedPath ($(if ($primed) { 'primed' } elseif ($node.present) { 'not primed: npx -y @microsoft/powerbi-modeling-mcp@0.5.0-beta.13 --help' } else { 'unavailable (Node absent - removed by device management?)' }))

if ($Save) {
    try {
        $dir = Split-Path $Save -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::WriteAllText($Save, (@{ checked_at = (Get-Date).ToString('o'); tools = $rows } | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    } catch {}
}
if ($Json) { [Console]::Out.Write(($rows | ConvertTo-Json -Depth 6 -Compress)) }
else { $rows | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize tool, present, version, note | Out-String -Width 200 }
exit 0
