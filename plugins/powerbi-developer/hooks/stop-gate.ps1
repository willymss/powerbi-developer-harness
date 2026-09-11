# Stop hook: block completion (exit 2) once per stop when report/theme/model mutations in this
# session were not followed by validate -> screenshot (when Desktop is available) -> review.
. (Join-Path $PSScriptRoot '_common.ps1')
$hookInput = Read-HookInput
if (-not $hookInput) { exit 0 }
$cfg = Get-HookConfig
if (-not $cfg.stop_gate) { exit 0 }
if ($hookInput.stop_hook_active -eq $true) { exit 0 }   # loop-safe: we already blocked once
$sid = [string]$hookInput.session_id
if (-not $sid) { exit 0 }
$ledger = @(Read-Ledger $sid)
if ($ledger.Count -eq 0) { exit 0 }

function LastTs([string[]]$Kinds, [bool]$OnlyOk = $true) {
    $t = $null
    foreach ($e in $ledger) {
        if ($Kinds -contains [string]$e.kind -and ((-not $OnlyOk) -or $e.ok -ne $false)) {
            try { $ts = [datetime]::Parse([string]$e.ts); if (-not $t -or $ts -gt $t) { $t = $ts } } catch {}
        }
    }
    return $t
}
function After($Since, [string[]]$Kinds) {
    $out = @()
    foreach ($e in $ledger) {
        if ($Kinds -contains [string]$e.kind) {
            try {
                if ($null -eq $Since) { $out += $e }
                elseif ([datetime]::Parse([string]$e.ts) -gt [datetime]$Since) { $out += $e }
            } catch { $out += $e }   # unparsable timestamp counts as unverified (fail closed)
        }
    }
    return $out
}

$mutKinds = @('mutation_report', 'mutation_theme', 'mutation_model')
$allMut = @($ledger | Where-Object { $mutKinds -contains [string]$_.kind })
if ($allMut.Count -eq 0) { exit 0 }

# context: last session record (report dir / pid) and whether Desktop was ever available
$session = $ledger | Where-Object { $_.kind -eq 'session' } | Select-Object -Last 1
$desktopAvailable = $false
if ($session -and $session.desktop_available -eq $true) { $desktopAvailable = $true }
if (@($ledger | Where-Object { $_.kind -in @('refresh', 'screenshot', 'verify_loop') -and $_.ok -ne $false }).Count -gt 0) { $desktopAvailable = $true }
$reportDir = '<report>'; $procId = '<pid>'
try {
    if ($session -and $session.instances -and @($session.instances).Count -gt 0) {
        $i0 = @($session.instances)[0]
        if ($i0.reportDir) { $reportDir = [string]$i0.reportDir }
        if ($i0.pid) { $procId = [string]$i0.pid }
    }
} catch {}
function Offenders($items) { ($items | Select-Object -Last 5 | ForEach-Object { "- [$($_.kind)] $($_.detail)" }) -join "`n" }

# 1. validate after the last mutation
$lastValidate = LastTs @('validate', 'verify_loop')
$unvalidated = After $lastValidate $mutKinds
if ($unvalidated.Count -gt 0) {
    $needTe = @($unvalidated | Where-Object { $_.kind -eq 'mutation_model' }).Count -gt 0
    Block ("[powerbi-developer stop gate] $($unvalidated.Count) mutation(s) since the last validation:`n" + (Offenders $unvalidated) +
        "`nRun: pbir -q validate `"$reportDir`" --all --json" + $(if ($needTe) { "  and  te validate -m <model.SemanticModel>" }) +
        " - report the result (errors, warnings triaged; TABLE_NOT_FOUND on '.'-prefixed tables is a known false positive), or state explicitly why validation is impossible right now.")
}

# 2. screenshot after the last report/theme mutation (only when Desktop is reachable)
if ($cfg.require_screenshot -and $desktopAvailable) {
    $lastShot = LastTs @('screenshot', 'verify_loop')
    $unseen = After $lastShot @('mutation_report', 'mutation_theme')
    if ($unseen.Count -gt 0) {
        Block ("[powerbi-developer stop gate] $($unseen.Count) report/theme mutation(s) were never rendered and captured:`n" + (Offenders $unseen) +
            "`nRun the guarded loop: pwsh -NoProfile -File `"$($script:ScriptsDir)\Invoke-VerifyLoop.ps1`" -Report `"$reportDir`" -DesktopPid $procId  (checks hasUnsavedChanges, refreshes, screenshots every page, writes _verify\<ts>\manifest.json). " +
            "If rendering cannot be verified (Desktop has unsaved changes, bridge down), say so explicitly in your summary instead of claiming the change works.")
    }
}

# 3. review after the last screenshot
if ($cfg.require_review) {
    $lastShot = LastTs @('screenshot', 'verify_loop')
    if ($lastShot) {
        $lastReview = LastTs @('review')
        if (-not $lastReview -or $lastReview -lt $lastShot) {
            Block ("[powerbi-developer stop gate] Screenshots were captured after the last review. Dispatch the pbi-visual-reviewer agent with the manifest path (_verify\<ts>\manifest.json), " +
                "or Read every PNG yourself and report findings as issue / location / severity / fix - then finish.")
        }
    }
}
exit 0
