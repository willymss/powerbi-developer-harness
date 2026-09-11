<#
.SYNOPSIS
  The guarded verify loop: validate -> Desktop state -> refresh (only when saved) -> screenshots -> manifest.
.DESCRIPTION
  1. pbir validate --all --json (errors -> exit 3; TABLE_NOT_FOUND on '.'-prefixed entities counted as known false positives)
  2. powerbi-report-author validate (second opinion, non-blocking, when installed)
  3. pbir bpa run -o json (non-blocking)
  4. Desktop state via Get-PbiDesktopState.ps1 (-DesktopPid wins; else the instance whose file matches -Report; else the single instance) -> none: exit 5 (validate-only)
  5. hasUnsavedChanges -> exit 4, NO refresh (same rule as the PreToolUse refresh guard)
  6. pbir desktop refresh (-m only with -Model); fallback powerbi-desktop reload --pid; both fail -> exit 6
  7. pbir desktop screenshot (--all or -Pages) -> fallback powerbi-desktop screenshot-all; zero PNGs -> exit 7
  8. writes <OutDir>\manifest.json and prints its path last (the post-command hook records verify_loop when it sees "ok": true / manifest.json)
  Exit codes: 0 ok, 3 validation errors, 4 unsaved, 5 no bridge, 6 refresh failed, 7 no screenshots, 9 unexpected.
.EXAMPLE
  pwsh -NoProfile -File Invoke-VerifyLoop.ps1 -Report "C:\dev\pbi\Sales\Sales.Report" -DesktopPid 1234 -Pages Overview,Detail -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Report,
    [string[]]$Pages = @(),
    [Alias('ProcessId')][int]$DesktopPid = 0,
    [switch]$Model,
    [switch]$SkipRefresh,
    [string]$OutDir = '',
    [int]$Scale = 2,
    [int]$Settle = 800,
    [int]$WaitSeconds = 60,
    [switch]$Strict,
    [switch]$Json
)
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
foreach ($d in @("$env:LOCALAPPDATA\Programs\te", "$env:APPDATA\npm")) { if ((Test-Path -LiteralPath $d) -and (($env:Path -split ';') -notcontains $d)) { $env:Path = "$env:Path;$d" } }
$enc = [Text.UTF8Encoding]::new($false)
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$Report = ($Report -replace '/', '\').TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $Report 'definition'))) { Write-Error "not a PBIR report folder: $Report"; exit 9 }
$projectDir = Split-Path $Report -Parent
if (-not $OutDir) { $OutDir = Join-Path $projectDir "_verify\$ts" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$pagesDir = Join-Path $OutDir 'pages'
New-Item -ItemType Directory -Force -Path $pagesDir | Out-Null
$manifest = [ordered]@{ ok = $false; timestamp = (Get-Date).ToString('o'); report = $Report; reportDir = $Report; pid = 0; currentFilePath = ''; unsaved = $null; bridge = 'unknown'
    validate = [ordered]@{ errors = -1; warnings = -1; known_false_positives = 0; file = '' }
    author_validate = [ordered]@{ ran = $false; errors = -1; file = '' }
    bpa = [ordered]@{ errors = -1; warnings = -1; file = '' }
    refresh = [ordered]@{ done = $false; path = ''; model = [bool]$Model; skipped = [bool]$SkipRefresh }
    pages = @(); expected_layout = ''; contract = ''; exit_code = 9; notes = @() }
function Finish([int]$code) {
    $manifest.exit_code = $code
    $manifest.ok = ($code -eq 0)
    $mp = Join-Path $OutDir 'manifest.json'
    [IO.File]::WriteAllText($mp, ($manifest | ConvertTo-Json -Depth 8), $enc)
    if ($Json) { [Console]::Out.Write(($manifest | ConvertTo-Json -Depth 8 -Compress)) }
    else {
        "verify loop: exit $code  ok=$($manifest.ok)  validate errors=$($manifest.validate.errors) warnings=$($manifest.validate.warnings) (known false positives $($manifest.validate.known_false_positives))"
        foreach ($n in $manifest.notes) { "  note: $n" }
        foreach ($p in $manifest.pages) { "  page $($p.displayName): $($p.png) ($($p.bytes) bytes)" }
        "manifest: $mp"
    }
    exit $code
}
function Run([string]$exe, [string[]]$argv, [int]$timeout = 300) {
    $r = [ordered]@{ ok = $false; stdout = ''; stderr = ''; exit = -1; timed_out = $false }
    try {
        $path = $exe
        $all = @(Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
        $pick = $all | Where-Object { $_ -match '\.exe$' } | Select-Object -First 1
        if (-not $pick) { $pick = $all | Where-Object { $_ -match '\.(cmd|bat)$' } | Select-Object -First 1 }
        if ($pick) { $path = $pick }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $quoted = ($argv | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
        if ($path -match '\.(cmd|bat)$') { $psi.FileName = $env:ComSpec; $psi.Arguments = "/d /c `"`"$path`" $quoted`"" } else { $psi.FileName = $path; $psi.Arguments = $quoted }
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = $enc
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($timeout * 1000)) { $r.timed_out = $true; try { $p.Kill($true) } catch {} }
        $r.stdout = $o.GetAwaiter().GetResult(); $r.stderr = $e.GetAwaiter().GetResult()
        if (-not $r.timed_out) { $r.exit = $p.ExitCode; $r.ok = ($p.ExitCode -eq 0) }
    } catch { $r.stderr = $_.Exception.Message }
    return $r
}
$layout = Join-Path $projectDir '_brief\build.layout.json'
if (Test-Path -LiteralPath $layout) { $manifest.expected_layout = $layout }
$spec = Join-Path $projectDir '_brief\report-spec.md'
if (Test-Path -LiteralPath $spec) { $manifest.contract = $spec }

try {
    # ---- 1. pbir validate
    $v = Run 'pbir' @('-q', 'validate', $Report, '--all', '--json')
    $vFile = Join-Path $OutDir 'validate.json'
    [IO.File]::WriteAllText($vFile, $v.stdout, $enc)
    $manifest.validate.file = $vFile
    # pbir validate --json: { status, errors: [ {code, message, location, details{schema_status,is_authoritative,...}} ], warnings: [...] }
    $errorsRaw = -1; $warnings = -1; $fp = 0; $degraded = 0
    try {
        $vj = $v.stdout | ConvertFrom-Json -Depth 50
        $eList = @(); $wList = @()
        if ($vj.errors -is [array]) { $eList = @($vj.errors) } elseif ($vj.errors -is [int] -or $vj.errors -is [long]) { $errorsRaw = [int]$vj.errors }
        if ($vj.warnings -is [array]) { $wList = @($vj.warnings) } elseif ($vj.warnings -is [int] -or $vj.warnings -is [long]) { $warnings = [int]$vj.warnings }
        if ($errorsRaw -lt 0) { $errorsRaw = $eList.Count }
        if ($warnings -lt 0) { $warnings = $wList.Count }
        # known false positive 1: SCHEMA_ERROR raised against a *degraded* bundled schema (declared version newer than pbir's bundle)
        $degraded = @($eList | Where-Object { $_.details -and ($_.details.schema_status -eq 'degraded' -or $_.details.is_authoritative -eq $false) }).Count
        # known false positive 2: TABLE_NOT_FOUND on '.'-prefixed entities (pbir splits at the first dot)
        $fp = @($wList | Where-Object { $_.code -eq 'TABLE_NOT_FOUND' -and ("$($_.message) $($_.details)" -match "'\.|\.[A-Za-z]") }).Count
    } catch { $errorsRaw = if ($v.ok) { 0 } else { 1 } }
    if ($errorsRaw -lt 0) { $errorsRaw = if ($v.ok) { 0 } else { 1 } }
    $errors = [Math]::Max(0, $errorsRaw - $degraded)
    $manifest.validate.errors = $errors; $manifest.validate.warnings = $warnings; $manifest.validate.known_false_positives = ($fp + $degraded)
    $manifest.validate.raw_errors = $errorsRaw; $manifest.validate.degraded_schema_errors = $degraded
    if ($degraded -gt 0) { $manifest.notes += "$degraded schema error(s) come from a degraded bundled schema (declared visualContainer version newer than pbir's bundle); treated as known false positives - re-run with 'pbir validate --allow-download-schemas' for an authoritative check" }
    if ($errors -gt 0) { $manifest.notes += "pbir validate reported $errors real error(s); see $vFile"; Finish 3 }
    if ($Strict -and $warnings -gt $fp) { $manifest.notes += "-Strict: $warnings warning(s) ($fp known false positives)"; Finish 3 }

    # ---- 2. powerbi-report-author validate (non-blocking)
    if (Get-Command powerbi-report-author -CommandType Application -ErrorAction SilentlyContinue) {
        $a = Run 'powerbi-report-author' @('validate', $Report, '--format', 'json') 120
        $aFile = Join-Path $OutDir 'author-validate.json'
        [IO.File]::WriteAllText($aFile, ($a.stdout + $a.stderr), $enc)
        $manifest.author_validate.ran = $true; $manifest.author_validate.file = $aFile
        $manifest.author_validate.errors = @([regex]::Matches($a.stdout, '"severity"\s*:\s*"error"')).Count
        if ($manifest.author_validate.errors -gt 0) { $manifest.notes += "powerbi-report-author validate flagged $($manifest.author_validate.errors) error(s) (second opinion; see $aFile)" }
    }
    # ---- 3. bpa (non-blocking)
    $b = Run 'pbir' @('-q', 'bpa', 'run', $Report, '-o', 'json') 180
    $bFile = Join-Path $OutDir 'bpa.json'
    [IO.File]::WriteAllText($bFile, $b.stdout, $enc)
    $manifest.bpa.file = $bFile
    $manifest.bpa.errors = @([regex]::Matches($b.stdout, '"severity"\s*:\s*"?(error|3)"?')).Count
    $manifest.bpa.warnings = @([regex]::Matches($b.stdout, '"severity"\s*:\s*"?(warning|2)"?')).Count

    # ---- 4. Desktop state
    $stateScript = Join-Path $PSScriptRoot 'Get-PbiDesktopState.ps1'
    $stArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $stateScript, '-Json', '-TimeoutSec', '12')
    if ($DesktopPid -gt 0) { $stArgs += @('-DesktopPid', "$DesktopPid") }
    $s = Run 'pwsh' $stArgs 30
    $state = $null
    try { $state = $s.stdout | ConvertFrom-Json -Depth 20 } catch {}
    $manifest.bridge = if ($state) { "$($state.status) ($($state.source))" } else { 'unknown' }
    $inst = @(); if ($state -and $state.instances) { $inst = @($state.instances) }
    $target = $null
    if ($DesktopPid -gt 0) { $target = $inst | Where-Object { $_.pid -eq $DesktopPid } | Select-Object -First 1 }
    if (-not $target) {
        $target = $inst | Where-Object { ([string]$_.reportDir).TrimEnd('\') -ieq $Report -or (Split-Path ([string]$_.currentFilePath) -Parent) -ieq $projectDir } | Select-Object -First 1
    }
    # No single-instance fallback here: refreshing/capturing a DIFFERENT open report would be wrong.
    if (-not $target) {
        $others = ($inst | ForEach-Object { "PID $($_.pid) = $($_.currentFilePath) (unsaved=$($_.hasUnsavedChanges))" }) -join '; '
        $manifest.notes += "no Desktop instance has THIS project open (bridge: $($manifest.bridge)$(if ($others) { "; running: $others" })); validate-only. Open the .pbip in Desktop (powerbi-desktop open <.pbip> or Start-Process; NOT pbir open, which resolves through the active profile) or pass -DesktopPid explicitly."
        Finish 5
    }
    $manifest.pid = [int]$target.pid; $manifest.currentFilePath = [string]$target.currentFilePath; $manifest.unsaved = [bool]$target.hasUnsavedChanges
    # ---- 5. unsaved
    if ($target.hasUnsavedChanges) {
        $manifest.notes += "Desktop PID $($target.pid) has UNSAVED changes: refresh skipped (it would force a save and could discard Desktop state). Ask the user to Save/discard, then re-run."
        Finish 4
    }
    # ---- 6. refresh
    if (-not $SkipRefresh) {
        $rArgs = @('-q', 'desktop', 'refresh', $Report, '--pid', "$($target.pid)", '--wait-seconds', "$WaitSeconds")
        if ($Model) { $rArgs += '-m' }
        $rr = Run 'pbir' $rArgs ($WaitSeconds + 60)
        if ($rr.ok) { $manifest.refresh.done = $true; $manifest.refresh.path = 'pbir' }
        elseif (Get-Command powerbi-desktop -CommandType Application -ErrorAction SilentlyContinue) {
            $rr2 = Run 'powerbi-desktop' @('reload', '--pid', "$($target.pid)", '--wait-seconds', "$WaitSeconds") ($WaitSeconds + 60)
            if ($rr2.ok) { $manifest.refresh.done = $true; $manifest.refresh.path = 'powerbi-desktop'; $manifest.notes += "pbir refresh failed ($($rr.stderr.Trim())); powerbi-desktop reload succeeded" }
            else { $manifest.notes += "refresh failed via pbir ($($rr.stderr.Trim())) and powerbi-desktop ($($rr2.stderr.Trim()))"; Finish 6 }
        } else { $manifest.notes += "refresh failed: $($rr.stderr.Trim()) $($rr.stdout.Trim())"; Finish 6 }
        Start-Sleep -Milliseconds ([Math]::Max(0, $Settle))
    }
    # ---- 7. screenshots
    $pngs = @()
    if ($Pages.Count -gt 0) {
        foreach ($pg in $Pages) {
            $safe = ($pg -replace '[\\/:*?"<>|]', '_')
            $out = Join-Path $pagesDir "$safe.png"
            $sc = Run 'pbir' @('-q', 'desktop', 'screenshot', "$Report/$pg.Page", '-o', $out, '--scale', "$Scale", '--pid', "$($target.pid)", '--json') 180
            if (Test-Path -LiteralPath $out) { $pngs += [ordered]@{ name = ''; displayName = $pg; png = $out; bytes = (Get-Item -LiteralPath $out).Length } }
            else { $manifest.notes += "screenshot failed for page '$pg': $($sc.stderr.Trim()) $($sc.stdout.Trim())" }
        }
    } else {
        $sc = Run 'pbir' @('-q', 'desktop', 'screenshot', $Report, '--all', '--output-dir', $pagesDir, '--scale', "$Scale", '--settle', "$Settle", '--pid', "$($target.pid)", '--json') 600
        $files = @(Get-ChildItem -LiteralPath $pagesDir -Filter '*.png' -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0 -and (Get-Command powerbi-desktop -CommandType Application -ErrorAction SilentlyContinue)) {
            $manifest.notes += "pbir screenshot --all produced nothing ($($sc.stderr.Trim())); trying powerbi-desktop screenshot-all"
            $null = Run 'powerbi-desktop' @('screenshot-all', '--pid', "$($target.pid)", '--output-dir', $pagesDir, '--scale', "$Scale", '--settle', "$Settle") 600
            $files = @(Get-ChildItem -LiteralPath $pagesDir -Filter '*.png' -ErrorAction SilentlyContinue)
        }
        foreach ($f in $files) {
            $dn = [IO.Path]::GetFileNameWithoutExtension($f.Name)
            $pageName = ''
            $hit = $target.pages | Where-Object { $_.displayName -eq $dn -or $_.name -eq $dn } | Select-Object -First 1
            if ($hit) { $pageName = $hit.name; $dn = $hit.displayName }
            $pngs += [ordered]@{ name = $pageName; displayName = $dn; png = $f.FullName; bytes = $f.Length }
        }
    }
    $manifest.pages = $pngs
    if ($pngs.Count -eq 0) { $manifest.notes += 'no screenshots captured'; Finish 7 }
    Finish 0
} catch {
    $manifest.notes += "unexpected: $($_.Exception.Message)"
    Finish 9
}
