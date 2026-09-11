# PostToolUse Bash|PowerShell: evidence ledger for pbir/te/TOM/bridge commands and an encoding
# guard for PBIP files the command names explicitly (heredocs, Set-Content, Out-File ...).
. (Join-Path $PSScriptRoot '_common.ps1')
$hookInput = Read-HookInput
if (-not $hookInput) { exit 0 }
$cfg = Get-HookConfig
if ($hookInput.tool_name -notin @('Bash', 'PowerShell')) { exit 0 }
$cmd = Get-CommandText $hookInput
if (-not $cmd) { exit 0 }

# ---- did the command succeed? ----
$ok = $true
$resp = $hookInput.tool_response
$respText = ''
try {
    if ($resp -is [string]) { $respText = $resp }
    elseif ($resp.stdout -ne $null -or $resp.stderr -ne $null) { $respText = ([string]$resp.stdout + "`n" + [string]$resp.stderr) }
    else { $respText = ($resp | ConvertTo-Json -Depth 6 -Compress) }
    if ($resp.exit_code -ne $null -and [int]$resp.exit_code -ne 0) { $ok = $false }
    if ($resp.interrupted -eq $true) { $ok = $false }
    if ($respText -match '(?i)traceback \(most recent call last\)') { $ok = $false }
} catch {}
if ($respText.Length -gt 4000) { $respText = $respText.Substring(0, 4000) }

# ---- ledger ----
$kinds = Get-CommandKinds $cmd
foreach ($k in @($kinds | Select-Object -Unique)) {
    $extra = @{}
    if ($k -eq 'verify_loop') {
        $extra.ok_manifest = ($respText -match '(?i)\bok\\?"?\s*[:=]\s*true' -or $respText -match '(?i)manifest\.json')
        if (-not $extra.ok_manifest) { $ok = $false }
    }
    if ($k -eq 'validate' -and $respText -match '(?i)\berrors?\\?"?\s*[:=]\s*([1-9]\d*)') { $extra.errors = [int]$matches[1]; $ok = $false }
    Add-Ledger $hookInput $k $cmd $ok $extra
}

# ---- encoding guard for explicitly named PBIP files written by shell means ----
if (-not $cfg.encoding_guard) { exit 0 }
$writes = ($cmd -match '(?i)(Set-Content|Out-File|Add-Content|WriteAllText|WriteAllLines|>{1,2}\s*["'']?[A-Za-z]:|\btee\b|\bsed\s+-i|cat\s*>|\bcp\b|Copy-Item)')
if (-not $writes) { exit 0 }
$tokens = @(Get-FileTokens $cmd)
$fixed = @(); $bad = @()
foreach ($t in $tokens) {
    $p = Normalize-Path $t
    if (-not (Test-PbipArtifactPath $p)) { continue }
    if ($p -match '(?i)\\\.pbi\\') { continue }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
    try {
        $bytes = [IO.File]::ReadAllBytes($p)
        $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        if ($hadBom -and $text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
        $lfOnly = ([regex]::Matches($text, '(?<!\r)\n')).Count
        if ($hadBom -or $lfOnly -gt 0) {
            $fixedText = $text -replace '\r?\n', "`r`n"
            $item = Get-Item -LiteralPath $p
            $wasRo = ($item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0
            if ($wasRo) { $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly }
            [IO.File]::WriteAllText($p, $fixedText, [Text.UTF8Encoding]::new($false))
            if ($wasRo) { try { (Get-Item -LiteralPath $p).Attributes = $item.Attributes -bor [IO.FileAttributes]::ReadOnly } catch {} }
            if ($hadBom) { $fixed += $p }
            $text = $fixedText
        }
        if ($p -match '(?i)\.(json|pbir|pbip|platform)$' -and -not (Get-Command jq -ErrorAction SilentlyContinue)) {
            try { $null = $text | ConvertFrom-Json -Depth 100 } catch { $bad += "$p ($($_.Exception.Message))" }
        }
        if ($p -match '(?i)\\[^\\]+\.report\\') { Add-Ledger $hookInput 'mutation_report' "shell write $p" $true }
        elseif ($p -match '(?i)\.tmdl$') { Add-Ledger $hookInput 'mutation_model' "shell write $p" $true }
    } catch {}
}
if ($fixed.Count) {
    Block ("UTF-8 BOM found and removed from: $($fixed -join ', ') (a BOM stops the whole PBIP opening in Desktop; pbir validate does not catch it). Line endings normalised to CRLF. " +
           "Write PBIP text with [IO.File]::WriteAllText(path, text, [Text.UTF8Encoding]::new(`$false)) - never Set-Content -Encoding UTF8 under Windows PowerShell 5.1.")
}
if ($bad.Count) { Block ("Invalid JSON after this command: $($bad -join '; '). Fix before Desktop sees it, or use pbir which only writes validated JSON.") }
exit 0
