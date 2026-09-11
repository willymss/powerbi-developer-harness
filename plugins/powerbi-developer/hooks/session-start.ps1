# SessionStart hook: toolchain + Desktop banner (plain stdout is injected as context). Always exit 0.
. (Join-Path $PSScriptRoot '_common.ps1')
$hookInput = Read-HookInput
$cfg = Get-HookConfig
if ($env:POWERBI_DEVELOPER_HOOKS -eq 'off') { Write-Output '[powerbi-developer] hooks disabled (POWERBI_DEVELOPER_HOOKS=off).'; exit 0 }

$source = ''
try { $source = [string]$hookInput.source } catch {}
$lines = New-Object System.Collections.Generic.List[string]
$maxLines = [int]$cfg.banner_max_lines
if ($maxLines -lt 8) { $maxLines = 8 }

# ---- Desktop (subprocess with timeout; a stalled bridge must not stall the session) ----
$desk = Get-DesktopState -TimeoutSec 14
$instances = @()
$desktopAvailable = $false
if ($desk -and $desk.instances) { $instances = @($desk.instances); $desktopAvailable = ($instances.Count -gt 0) }

# ---- tools (in-process; each probe has its own timeout) ----
$tools = @()
if ($source -ne 'compact') {
    try {
        $toolScript = Join-Path $script:ScriptsDir 'Get-PbiToolStatus.ps1'
        $statusPath = Get-PluginDataPath 'tool-status.json'
        $toolJson = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $toolScript -Fast -Json -Save $statusPath 2>$null
        if ($toolJson) { $tools = @(($toolJson -join '') | ConvertFrom-Json -Depth 6) }
    } catch {}
}
function T([string]$name) { $tools | Where-Object { $_.tool -eq $name } | Select-Object -First 1 }
function Mark($row) { if ($row -and $row.present) { if ($row.version) { $row.version } else { 'ok' } } else { 'missing' } }

if ($source -ne 'compact') {
    $pbir = T 'pbir'; $te = T 'te'; $pd = T 'powerbi-desktop'; $pra = T 'powerbi-report-author'; $node = T 'node'; $uv = T 'uv'
    $fab = T 'fab'; $az = T 'az'; $jq = T 'jq'; $ps5 = T 'powershell 5.1'; $adomd = T 'adomd'; $mcp = T 'powerbi-modeling-mcp (npx cache)'
    $lines.Add("[powerbi-developer] tools: pbir $(Mark $pbir) | te $(Mark $te) | powerbi-desktop $(Mark $pd) | powerbi-report-author $(Mark $pra) | node $(Mark $node) | uv $(Mark $uv) | PS5.1 $(Mark $ps5) | MCP cache $(if ($mcp -and $mcp.present) { 'primed' } else { 'not primed' })")
    $optional = @()
    foreach ($pair in @(@('fab', $fab), @('az', $az), @('jq', $jq), @('adomd', $adomd))) { if (-not ($pair[1] -and $pair[1].present)) { $optional += $pair[0] } }
    $missing = @()
    foreach ($pair in @(@('pbir', $pbir), @('te', $te), @('powerbi-desktop', $pd), @('powerbi-report-author', $pra), @('node', $node), @('uv', $uv))) { if (-not ($pair[1] -and $pair[1].present)) { $missing += $pair[0] } }
    if ($missing.Count) { $lines.Add("  MISSING: $($missing -join ', ') -> run /powerbi-developer:setup (pbir-only path still works; Node tools are optional and device management may have removed Node).") }
    if ($optional.Count) { $lines.Add("  optional absent: $($optional -join ', ')") }
    if ($pbir -and $pbir.note) { $lines.Add("  pbir: $($pbir.note)") }
    if ($te -and $te.note) { $lines.Add("  te: $($te.note)") }
    if ($te -and -not $te.present -and $te.note) { $lines.Add("  te: $($te.note)") }
}

# ---- Desktop lines ----
if ($desktopAvailable) {
    $lines.Add("Desktop: $($instances.Count) instance(s) (source: $($desk.source))")
    foreach ($i in $instances) {
        $flags = @()
        if ($i.hasUnsavedChanges) { $flags += 'UNSAVED CHANGES - do not refresh until saved' }
        if (Test-OneDrivePath ([string]$i.currentFilePath)) { $flags += 'OneDrive path: rm/cp/restore hazard' }
        try {
            $dir = [string]$i.reportDir
            if ($dir) {
                $base = Split-Path $dir -Parent
                $model = Join-Path $base (([IO.Path]::GetFileNameWithoutExtension($i.currentFilePath)) + '.SemanticModel')
                if (Test-Path -LiteralPath (Join-Path $model '.pbi\unappliedChanges.json')) { $flags += 'unappliedChanges.json PRESENT: do not edit M partitions on disk' }
                if (-not (Test-Path -LiteralPath (Join-Path $base '.git'))) { $flags += 'no git repo' }
            }
        } catch {}
        $lines.Add("  PID $($i.pid): $($i.currentFilePath) | unsaved=$($i.hasUnsavedChanges) | pages=$(@($i.pages).Count)$(if ($flags.Count) { ' | ' + ($flags -join '; ') })")
    }
} else {
    $lines.Add("Desktop: not connected (no bridge). Open the PBIP in Power BI Desktop with the preview feature 'Enable external tool access to Power BI Desktop through secure local APIs' on; until then work is validate-only.")
}

# ---- pbir active profile ----
try {
    $cfgPath = Join-Path $env:APPDATA 'pbir-tools\config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        $pc = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
        $ap = [string]$pc.active_profile
        if ($ap) {
            $prof = $null
            try { $prof = $pc.profiles.$ap } catch {}
            $rep = if ($prof -and $prof.report_path) { [string]$prof.report_path } elseif ($prof -and $prof.report) { [string]$prof.report } else { '' }
            $bd = if ($prof -and $prof.base_dir) { [string]$prof.base_dir } elseif ($prof -and $prof.cwd) { [string]$prof.cwd } else { '' }
            $lines.Add("pbir active profile: '$ap' -> $rep $(if ($bd) { "(base $bd)" }) - relative pbir paths resolve HERE; pass explicit report paths.")
        }
    }
} catch {}

if ($source -ne 'compact') {
    $lines.Add('Rules: (1) pbir is the only report-JSON writer; never hand-edit .Report JSON, report.json, mobileState.json, *DiagramLayout.json or .pbi\*. (2) Model writes: te -> modeling MCP -> TOM (powershell.exe 5.1) -> tmdl; TOM and TMDL must agree in the same turn.')
    $lines.Add('(3) Check hasUnsavedChanges before any canvas refresh; Desktop''s own external-changes prompt is the safe direction. (4) PBIP files: UTF-8 without BOM + CRLF. (5) Run plugin .ps1 via the PowerShell tool with pwsh -File. (6) Always pbir -q and --json; ask before commit, publish, rm, restore, clear-formatting.')
    $lines.Add('Workflow: /powerbi-developer (skill) -> _brief/report-spec.md approval -> build -> pbir validate -> Invoke-VerifyLoop.ps1 -> pbi-visual-reviewer -> pbi-spec-verifier. The Stop hook blocks completion until mutations are validated, screenshotted and reviewed.')
}

# trim
$out = @($lines | Select-Object -First $maxLines)
Write-Output ($out -join "`n")

# ledger + housekeeping
try {
    $sid = [string]$hookInput.session_id
    if ($sid) {
        $inst = @($instances | ForEach-Object { [ordered]@{ pid = $_.pid; file = $_.currentFilePath; reportDir = $_.reportDir; unsaved = $_.hasUnsavedChanges } })
        Add-Ledger $hookInput 'session' "source=$source" $true @{ desktop_available = $desktopAvailable; instances = $inst }
    }
    Remove-OldLedgers 14
} catch {}
exit 0
