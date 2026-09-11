# PostToolUse Edit|Write: encoding guard (BOM strip + CRLF + JSON parse) and evidence ledger.
. (Join-Path $PSScriptRoot '_common.ps1')
$hookInput = Read-HookInput
if (-not $hookInput) { exit 0 }
$cfg = Get-HookConfig
if ($hookInput.tool_name -notin @('Edit', 'Write', 'MultiEdit')) { exit 0 }
$path = Normalize-Path (Get-FilePathInput $hookInput)
if (-not $path) { exit 0 }
if (-not (Test-PbipArtifactPath $path)) { exit 0 }
if ($path -match '(?i)\\\.pbi\\') { exit 0 }

# ---- ledger first (the edit already happened) ----
$lower = $path.ToLowerInvariant()
$kind = $null
if ($lower -match '\\staticresources\\registeredresources\\') { $kind = 'mutation_theme' }
elseif ($lower -match '\.tmdl$') { $kind = 'mutation_model' }
elseif ($lower -match '\\[^\\]+\.report\\') { $kind = 'mutation_report' }
if ($kind) { Add-Ledger $hookInput $kind "hand-edit $path" $true @{ path = $path } }

if (-not $cfg.encoding_guard) { exit 0 }
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 0 }

$notes = @()
try {
    $bytes = [IO.File]::ReadAllBytes($path)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($hadBom -and $text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    $lfOnly = ([regex]::Matches($text, '(?<!\r)\n')).Count
    $needsRewrite = $hadBom -or ($lfOnly -gt 0)
    if ($needsRewrite) {
        $fixedText = $text -replace '\r?\n', "`r`n"
        $item = Get-Item -LiteralPath $path
        $wasRo = ($item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0
        if ($wasRo) { $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly }
        [IO.File]::WriteAllText($path, $fixedText, [Text.UTF8Encoding]::new($false))
        if ($wasRo) { try { (Get-Item -LiteralPath $path).Attributes = $item.Attributes -bor [IO.FileAttributes]::ReadOnly } catch {} }
        $text = $fixedText
    }
    $jsonBad = $null
    if ($path -match '(?i)\.(json|pbir|pbip|platform)$') {
        $jqPresent = $null -ne (Get-Command jq -ErrorAction SilentlyContinue)
        if (-not $jqPresent) {   # with jq installed the pbip plugin's own hooks validate JSON
            try { $null = $text | ConvertFrom-Json -Depth 100 } catch { $jsonBad = $_.Exception.Message }
        }
    }
    if ($hadBom) {
        Block ("UTF-8 BOM found and removed from '$path' (a BOM stops the whole PBIP opening in Desktop; pbir validate does not catch it). " +
               "Line endings normalised to CRLF. Write PBIP text with [IO.File]::WriteAllText(path, text, [Text.UTF8Encoding]::new(`$false)) or use pbir/te - never Set-Content -Encoding UTF8 (PS 5.1 adds a BOM).")
    }
    if ($jsonBad) {
        Block ("'$path' is not valid JSON after this edit: $jsonBad. Fix it now (Desktop will refuse the project) - or use pbir, which only writes validated JSON.")
    }
    if ($lfOnly -gt 0) { $notes += "Line endings in '$path' were LF; normalised to CRLF (PBIP convention)." }
} catch { exit 0 }

if ($notes.Count) { Emit-Context 'PostToolUse' ($notes -join ' ') }
exit 0
