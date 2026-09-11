# Evidence ledger for non-shell events: Read of screenshot PNGs (= review), modeling-MCP tool calls
# (= model mutation / read), and SubagentStop of the reviewer agents (= review / spec_verify).
. (Join-Path $PSScriptRoot '_common.ps1')
$hookInput = Read-HookInput
if (-not $hookInput) { exit 0 }
$cfg = Get-HookConfig
if (-not $cfg.ledger) { exit 0 }
$ev = [string]$hookInput.hook_event_name
$tool = [string]$hookInput.tool_name

if ($ev -eq 'PostToolUse' -and $tool -eq 'Read') {
    $p = Normalize-Path (Get-FilePathInput $hookInput)
    if ($p -match '(?i)\.png$' -and $p -match '(?i)\\(_verify|screenshots|pages)\\') { Add-Ledger $hookInput 'review' "read $p" $true }
    exit 0
}
if ($ev -eq 'PostToolUse' -and $tool -match '^mcp__plugin_powerbi-developer_powerbi-modeling-mcp__') {
    $name = $tool -replace '^mcp__plugin_powerbi-developer_powerbi-modeling-mcp__', ''
    $kind = if ($name -match '(?i)^(create|update|delete|add|remove|set|deploy|rename|save|apply|execute_tmsl|refresh)') { 'mutation_model' } else { 'model_read' }
    Add-Ledger $hookInput $kind "mcp $name" $true
    exit 0
}
if ($ev -eq 'SubagentStop') {
    $agent = ''
    try { $agent = [string]$hookInput.agent_type } catch {}
    if (-not $agent) { try { $agent = [string]$hookInput.agent_name } catch {} }
    if ($agent -match '(?i)visual-reviewer') { Add-Ledger $hookInput 'review' "agent $agent" $true }
    elseif ($agent -match '(?i)spec-verifier') { Add-Ledger $hookInput 'spec_verify' "agent $agent" $true }
    elseif (-not $agent) { Add-Ledger $hookInput 'review' 'agent (type unknown; matched by hook matcher)' $true }
    exit 0
}
exit 0
