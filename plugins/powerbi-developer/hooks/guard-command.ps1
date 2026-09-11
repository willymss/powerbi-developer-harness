# PreToolUse Bash|PowerShell: (1) refresh guard - deny a Desktop canvas reload while Desktop has
# unsaved changes, ask on model re-apply; (2) hazard guard - ask before destructive / irreversible
# pbir, te, TOM and MCP operations. Read-only commands exit 0 in a few ms. First matching rule wins.
. (Join-Path $PSScriptRoot '_common.ps1')
$hookInput = Read-HookInput
if (-not $hookInput) { exit 0 }
$cfg = Get-HookConfig
if ($hookInput.tool_name -notin @('Bash', 'PowerShell')) { exit 0 }
$cmd = Get-CommandText $hookInput
if (-not $cmd) { exit 0 }
$od = if (Test-OneDrivePath $cmd) { ' Path is under OneDrive: directories carry a ReadOnly attribute that OneDrive re-applies within minutes, and sync locks cause transient Permission denied.' } else { '' }

# ------------------------------------------------------------------ 1. refresh guard
$isRefresh = ($cmd -match '(?i)\bpbir(\.exe)?\b[^\n;|&]*\sdesktop\s+(refresh|reload)\b') -or
             ($cmd -match '(?i)\bpowerbi-desktop(\.cmd|\.exe)?\s+reload\b') -or
             ($cmd -match '(?i)file\.reload') -or
             ($cmd -match '(?i)PBIR_DESKTOP_AUTO_REFRESH\s*[=:]\s*[''"]?1')
if ($cfg.refresh_guard -and $isRefresh) {
    $isRaw = ($cmd -match '(?i)file\.reload')
    $wantsModel = ($cmd -match '(?i)\sdesktop\s+(refresh|reload)\b[^\n;|&]*\s(-m|--model)\b') -or ($cmd -match '(?i)reloadModelDefinition\s*[=:]\s*\$?true')
    $pidInCmd = 0
    if ($cmd -match '(?i)--pid\s+(\d+)') { $pidInCmd = [int]$matches[1] }
    $state = Get-DesktopState -TimeoutSec 14
    $instances = @()
    if ($state -and $state.instances) { $instances = @($state.instances) }
    Add-Ledger $hookInput 'refresh_attempt' $cmd $true @{ instances = $instances.Count }
    if ($instances.Count -gt 0) {
        # resolve the target instance
        $target = $null
        if ($pidInCmd -gt 0) { $target = $instances | Where-Object { $_.pid -eq $pidInCmd } | Select-Object -First 1 }
        if (-not $target) {
            $pathTok = $null
            foreach ($m in [regex]::Matches($cmd, '["'']([^"''\r\n]+?\.(Report|pbip))(?:[/\\][^"''\r\n]*)?["'']')) { $pathTok = $m.Groups[1].Value; break }
            if (-not $pathTok -and $cmd -match '(?<![\w"''])([A-Za-z]:[\\/][^\s"''<>|]+?\.(Report|pbip))') { $pathTok = $matches[1] }
            if ($pathTok) {
                $want = (Normalize-Path $pathTok).TrimEnd('\')
                $wantLeaf = Split-Path $want -Leaf
                $target = $instances | Where-Object {
                    $d = Normalize-Path ([string]$_.reportDir); $f = Normalize-Path ([string]$_.currentFilePath)
                    ($d -and ($d.TrimEnd('\') -ieq $want)) -or ($f -and ($f -ieq $want)) -or
                    ($d -and ((Split-Path $d -Leaf) -ieq $wantLeaf)) -or ($f -and (([IO.Path]::GetFileNameWithoutExtension($f) + '.Report') -ieq $wantLeaf))
                } | Select-Object -First 1
            }
        }
        if (-not $target -and $instances.Count -eq 1) { $target = $instances[0] }
        if (-not $target) {
            $list = ($instances | ForEach-Object { "PID $($_.pid) = $($_.currentFilePath) (unsaved=$($_.hasUnsavedChanges))" }) -join '; '
            Emit-Decision 'PreToolUse' 'ask' "Several Power BI Desktop instances are running and the command names none of them explicitly: $list. Re-run with --pid <pid> (pbir desktop refresh --pid N) so the right canvas is reloaded."
        }
        if ($target.hasUnsavedChanges) {
            Emit-Decision 'PreToolUse' 'deny' ("Desktop PID $($target.pid) ($($target.currentFilePath)) has UNSAVED changes. A canvas refresh forces a save that rewrites the whole report definition on disk and can discard unsaved Desktop UI state or overwrite the on-disk edits you just made. " +
                "Ask the user to Save (or discard) in Desktop, re-run 'pbir -q desktop status --json' until hasUnsavedChanges is false, then retry. The safe direction is Desktop's own external-changes prompt (it applies disk -> canvas without forcing a save).")
        }
        if ($wantsModel -and $cfg.ask_on_model_reload) {
            Emit-Decision 'PreToolUse' 'ask' ("This reload re-applies the MODEL definition (TMDL) into Desktop PID $($target.pid). Confirm: no TOM-only (in-memory) edits are pending - both stores must agree before either direction is applied - and 'te validate -m <model>' passed on the on-disk TMDL. A reload with a broken TMDL leaves the model unprocessed.")
        }
        if ($isRaw) {
            Emit-Decision 'PreToolUse' 'ask' "Raw named-pipe file.reload/v1 call. Prefer 'pbir -q desktop refresh <report> --pid $($target.pid)' (or powerbi-desktop reload --pid) which check state first. Proceed only if pbir and powerbi-desktop both failed."
        }
    }
    exit 0   # bridge not ready / no instances: let the tool report its own error
}

# ------------------------------------------------------------------ 2. hazard guard (ask)
if (-not $cfg.hazard_gate) { exit 0 }
$pbirCmd = ($cmd -match '(?im)(^|[\s;&|(])pbir(\.exe)?\s')
$rules = @()
if ($pbirCmd) {
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*\spublish\b'; why = 'pbir publish overwrites the target report in the Fabric workspace. Confirm the workspace/report destination, that "pbir validate --all" is clean, that screenshots were reviewed, and that the delivery target actually includes publishing.' }
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*\srestore\b'; why = 'pbir restore has failed destructively before: it deleted every visual.json on an unrelated page and its own rollback did not put them back (OneDrive ReadOnly dirs break rmtree). Prefer Copy-Item -Path (Join-Path $backup "*") from the pbir backup and verify by Get-FileHash, never by exit code.' }
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*\srm\s'; why = 'pbir rm deletes visual.json first and then fails on ReadOnly directories, leaving an empty folder that blocks reuse of that visual name. Take "pbir backup <report> -m <why>" first and delete the empty folder afterwards if the command fails.' }
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*\scp\s[^\n;|&]*\.Visual'; why = 'pbir cp on a VISUAL assigns a NEW internal name; bookmarks reference visuals by name, so every bookmark driving the target silently stops working. There is no in-place replace primitive. Use pbir set / batch on the existing visual instead, or accept re-pointing the bookmarks.' }
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*\sclear-formatting\b'; why = 'clear-formatting strips every formatting override on the target set irreversibly. Take a pbir backup first and confirm the target glob is as narrow as intended.' }
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*\sdax\s+measures?\s+(rm|remove|clear)\b'; why = 'Removing report-extension measures breaks every visual and conditional-formatting rule bound to them. Run "pbir fields find" for the measure first and confirm no bindings remain.' }
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*\stheme\s+apply-template\b'; why = 'theme apply-template replaces the report theme wholesale; visual-level overrides may still win and Desktop caches themes by file name (reopen Desktop to judge). Backup first.' }
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*\sreport\s+(convert|merge|split)'; why = 'Report-level convert/merge/split rewrites the whole report structure. Backup first and confirm the report is not open with unsaved changes in Desktop.' }
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*--rawdog\b'; why = '--rawdog skips every validation check. pbir writes are trusted precisely because they validate; only use this when the model is unreachable and re-validate immediately afterwards.' }
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*\sbpa\s+run\b[^\n;|&]*--fix[^\n;|&]*--save'; why = 'bpa run --fix --save applies every auto-fix expression to the report. Run the same command with --dry-run first and review the list.' }
    $rules += @{ rx = '\bpbir(\.exe)?\b[^\n;|&]*\sfields\s+(replace|replace-table|rename)\b(?![^\n;|&]*--dry-run)'; why = 'Field replace/rename rewrites bindings across the report; field-parameter and SWITCH literals are NOT updated and blank silently. Run with --dry-run first, then validate --fields and dispatch pbip:pbip-validator.' }
}
$rules += @{ rx = '(^|[\s;&|(])te(\.exe)?\s[^\n;|&]*(--save\b|\sdeploy\b|\s(remove|rm|move|mv)\s)'; why = 'te is about to write the model (save/deploy/remove/move). After it saves, the on-disk TMDL is what Desktop applies on its external-changes prompt - never leave TOM (live) and TMDL (disk) disagreeing across a turn, and run "te validate" afterwards. te deploy targets a workspace: confirm the target.' }
$rules += @{ rx = '\.SaveChanges\s*\('; why = 'TOM SaveChanges writes the LIVE Desktop model only. In the same turn, write the same expression to the TMDL on disk (both stores must agree) and back up the original expression so a revert is one command. SaveChanges is atomic per batch: one rejected property fails the whole batch.' }
$rules += @{ rx = 'powerbi-modeling-mcp[^\n]*--skipconfirmation'; why = 'Running the modeling MCP with --skipconfirmation removes its own write confirmations. Keep confirmations on unless the user asked for unattended mode.' }
$rules += @{ rx = '(^|[\s;&|(])git\s+(push\s+[^\n;|&]*--force|reset\s+--hard|clean\s+-[a-z]*f)'; why = 'Destructive git operation. The harness never force-pushes or hard-resets; ask the user.' }

foreach ($r in $rules) {
    if ($cmd -match ('(?i)' + $r.rx)) {
        Emit-Decision 'PreToolUse' 'ask' ($r.why + $od)
    }
}
exit 0
