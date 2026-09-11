<#
.SYNOPSIS
  Check (and optionally fix) PBIP text files for UTF-8 BOM, CRLF line endings and JSON validity.
.DESCRIPTION
  A UTF-8 BOM in any .tmdl/.json/.pbir/.pbip/.platform file stops Power BI Desktop from opening the
  whole project; pbir validate does not catch it. Skips \.pbi\, \_verify\, \_brief\.
  Exit 0 when clean, 2 when issues were found (or remain after -Fix).
.EXAMPLE
  pwsh -File Test-Utf8NoBom.ps1 -Path "C:\dev\pbi\Sales" -Recurse
  pwsh -File Test-Utf8NoBom.ps1 -Path "C:\dev\pbi\Sales\Sales.Report\definition\pages\p1\page.json" -Fix
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$Recurse,
    [switch]$Fix,
    [switch]$Json
)
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
$exts = @('.tmdl', '.json', '.pbir', '.pbip', '.platform')

function Test-OneFile([string]$File, [bool]$DoFix) {
    $r = [ordered]@{ path = $File; bom = $false; line_endings = 'crlf'; json_valid = $true; fixed = $false; error = '' }
    try {
        $bytes = [IO.File]::ReadAllBytes($File)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $r.bom = $true }
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        if ($r.bom -and $text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
        $lf = ([regex]::Matches($text, '(?<!\r)\n')).Count
        $crlf = ([regex]::Matches($text, '\r\n')).Count
        if ($lf -gt 0 -and $crlf -gt 0) { $r.line_endings = 'mixed' } elseif ($lf -gt 0) { $r.line_endings = 'lf' } elseif ($crlf -eq 0) { $r.line_endings = 'none' }
        $ext = [IO.Path]::GetExtension($File).ToLowerInvariant()
        if ($ext -in @('.json', '.pbir', '.pbip', '.platform')) {
            try { $null = $text | ConvertFrom-Json -Depth 100 } catch { $r.json_valid = $false; $r.error = $_.Exception.Message }
        }
        if ($DoFix -and ($r.bom -or $r.line_endings -in @('lf', 'mixed'))) {
            $fixedText = $text -replace '\r?\n', "`r`n"
            $item = Get-Item -LiteralPath $File
            $wasRo = ($item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0
            if ($wasRo) { $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly }
            [IO.File]::WriteAllText($File, $fixedText, [Text.UTF8Encoding]::new($false))
            if ($wasRo) { (Get-Item -LiteralPath $File).Attributes = $item.Attributes -bor [IO.FileAttributes]::ReadOnly }
            $r.fixed = $true; $r.bom = $false; $r.line_endings = 'crlf'
        }
    } catch { $r.error = $_.Exception.Message }
    return $r
}

$files = @()
if (Test-Path -LiteralPath $Path -PathType Container) {
    $files = Get-ChildItem -LiteralPath $Path -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
        Where-Object { $exts -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch '(?i)\\(\.pbi|_verify|_brief|\.git|node_modules)\\' } |
        ForEach-Object { $_.FullName }
} elseif (Test-Path -LiteralPath $Path -PathType Leaf) { $files = @((Get-Item -LiteralPath $Path).FullName) }
else { Write-Error "Path not found: $Path"; exit 2 }

$results = @()
foreach ($f in $files) { $results += (Test-OneFile $f $Fix) }
$issues = @($results | Where-Object { $_.bom -or $_.line_endings -in @('lf', 'mixed') -or -not $_.json_valid -or $_.error })
if ($Json) { [Console]::Out.Write((@{ files = $results.Count; issues = $issues.Count; results = $results } | ConvertTo-Json -Depth 5 -Compress)) }
else {
    "$($results.Count) file(s) checked, $($issues.Count) with issues" + $(if ($Fix) { " (fix applied where possible)" })
    foreach ($i in $issues) { "  $($i.path): bom=$($i.bom) endings=$($i.line_endings) json_valid=$($i.json_valid) fixed=$($i.fixed) $($i.error)" }
}
if ($issues.Count -gt 0) { exit 2 } else { exit 0 }
