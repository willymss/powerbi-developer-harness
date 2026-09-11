# PreToolUse Edit|Write: pbir is the only writer of report JSON; the model cascade owns TMDL.
. (Join-Path $PSScriptRoot '_common.ps1')
$hookInput = Read-HookInput
if (-not $hookInput) { exit 0 }
$cfg = Get-HookConfig
if (-not $cfg.hand_edit_gate) { exit 0 }
if ($hookInput.tool_name -notin @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')) { exit 0 }

$path = Normalize-Path (Get-FilePathInput $hookInput)
if (-not $path) { exit 0 }
if (-not (Test-PbipArtifactPath $path)) { exit 0 }
$lower = $path.ToLowerInvariant()
$od = if (Test-OneDrivePath $path) { ' Path is under OneDrive (ReadOnly attribute + sync locks): expect transient write failures.' } else { '' }

# --- deny: undocumented / Desktop-owned files ---
if ($lower -match '\\definition\\report\.json$' -or $lower -match '\\mobilestate\.json$' -or
    $lower -match '\\semanticmodeldiagramlayout\.json$' -or $lower -match '\\diagramlayout\.json$' -or $lower -match '\\\.pbi\\') {
    Emit-Decision 'PreToolUse' 'deny' ("Hand edit blocked: '$path' has an undocumented schema and Power BI Desktop rejects or overwrites external edits to it (report.json, mobileState.json, *DiagramLayout.json, .pbi\*). " +
        "Use pbir instead: 'pbir -q set ...', 'pbir -q theme ...', 'pbir -q pages ...'. If pbir has no operation for this change, stop and report the gap rather than editing by hand." + $od)
}

# --- ask: themes ---
if ($lower -match '\\staticresources\\registeredresources\\[^\\]+\.json$') {
    Emit-Decision 'PreToolUse' 'ask' ("Theme file hand edit: prefer 'pbir -q theme set-colors|set-fonts|set-formatting|build' (validated writes). " +
        "Desktop caches themes by FILE NAME - after editing, either rename the theme (pbir theme rename) or close and reopen Desktop before judging the result; a canvas refresh will not show theme changes." + $od)
}

# --- ask: TMDL ---
if ($lower -match '\.tmdl$') {
    Emit-Decision 'PreToolUse' 'ask' ("TMDL hand edit: the model cascade is te (te set/add ... --save) -> powerbi-modeling-mcp -> TOM via connect-pbid (powershell.exe 5.1) -> tmdl skill. " +
        "If this edit is deliberate: write UTF-8 WITHOUT BOM with CRLF, keep TOM and disk in agreement in the same turn, and run 'te validate -m <model>' afterwards - an offline TMDL parse is NOT DAX validation (reserved VAR names like 'cell' only fail on live load)." + $od)
}

# --- ask: everything else under the PBIP ---
Emit-Decision 'PreToolUse' 'ask' ("PBIP artefact hand edit: '$path'. pbir is the only report writer in this harness - use 'pbir -q set/add/visuals/pages/filters/bookmarks ...' or a 'pbir batch' spec (validated, schema-aware, no BOM). " +
    "If pbir lacks the operation, stop and report the gap. If you proceed anyway: UTF-8 without BOM, CRLF, then 'pbir -q validate <report> --all --json'." + $od)
