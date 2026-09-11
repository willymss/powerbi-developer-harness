<#
.SYNOPSIS
  Checks run before every push and in CI: manifests, PowerShell syntax, Python syntax, portability.
.DESCRIPTION
  1. claude plugin validate on the marketplace and (strict) on every plugin, when the claude CLI is present.
  2. Every .ps1 parses with the PowerShell parser.
  3. Every .py compiles (python, or uv run python).
  4. No tracked text file hardcodes a user profile path or a pinned data-goblin cache version.
  Exit 0 = clean, 1 = at least one failure.
#>
[CmdletBinding()]
param([switch]$SkipClaude)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Fail([string]$msg) { Write-Host "FAIL  $msg" -ForegroundColor Red; $script:fail++ }
function Pass([string]$msg) { Write-Host "ok    $msg" }

# 1. manifests: errors fail; warnings fail too (strict), except the deliberate missing plugin version
#    (plugins carry no version so every pushed commit is picked up as an update)
function Test-Manifest([string]$Path, [string]$Label) {
    $raw = claude plugin validate $Path --json 2>&1
    try { $r = ($raw -join "`n") | ConvertFrom-Json } catch { Fail "${Label}: unreadable validate output`n$($raw -join "`n")"; return }
    $errs = @($r.manifest.errors) + @($r.contents | ForEach-Object { $_.errors })
    $warns = @(@($r.manifest.warnings) + @($r.contents | ForEach-Object { $_.warnings }) |
        Where-Object { $_ -and $_.message -notmatch '^No version specified' })
    $errs = @($errs | Where-Object { $_ })
    if (-not $r.success -or $errs.Count -or $warns.Count) {
        Fail "${Label}: $(@($errs + $warns | ForEach-Object { "$($_.path): $($_.message)" }) -join '; ')"
    } else { Pass $Label }
}
if (-not $SkipClaude -and (Get-Command claude -ErrorAction SilentlyContinue)) {
    Test-Manifest $root 'marketplace manifest'
    foreach ($p in Get-ChildItem (Join-Path $root 'plugins') -Directory) { Test-Manifest $p.FullName "plugin $($p.Name)" }
} else { Write-Host 'skip  claude plugin validate (claude CLI not found or -SkipClaude)' }

# 2. PowerShell syntax
$before = $fail
foreach ($f in Get-ChildItem $root -Recurse -File -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\\.git\\' }) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors) { Fail "$($f.FullName.Substring($root.Length + 1)): $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))" }
}
if ($fail -eq $before) { Pass 'PowerShell parse' }

# 3. Python syntax
$py = @(Get-ChildItem $root -Recurse -File -Filter *.py | Where-Object { $_.FullName -notmatch '\\\.git\\' })
if ($py.Count) {
    $code = "import ast,sys`nfor p in sys.argv[1:]:`n    ast.parse(open(p,encoding='utf-8').read(),p)"
    $argsPy = @('-c', $code) + $py.FullName
    $python = Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
    if (Get-Command uv -ErrorAction SilentlyContinue) { $out = & uv run --no-project python @argsPy 2>&1 }
    elseif ($python) { $out = & $python.Source @argsPy 2>&1 }
    else { $out = 'no python (install uv or Python)'; $global:LASTEXITCODE = 1 }
    if ($LASTEXITCODE) { Fail "Python syntax`n$($out -join "`n")" } else { Pass "Python syntax ($($py.Count) files)" }
}

# 4. portability
$tracked = @(git -C $root ls-files 2>$null)
if (-not $tracked.Count) { $tracked = @(Get-ChildItem $root -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object { $_.FullName.Substring($root.Length + 1) }) }
$patterns = @('[A-Za-z]:\\Users\\[^\\<%$]', 'power-bi-agentic-development[\\/][a-z-]+[\\/]\d+\.\d+')
$before = $fail
foreach ($rel in $tracked) {
    $full = Join-Path $root $rel
    if ($rel -match '\.(png|jpg|pdf|pyc|zip)$' -or -not (Test-Path -LiteralPath $full)) { continue }
    $text = Get-Content -LiteralPath $full -Raw
    foreach ($pat in $patterns) {
        if ($text -match $pat) { Fail "${rel}: matches /$pat/ ('$($Matches[0])')" }
    }
}
if ($fail -eq $before) { Pass 'portability scan' }

if ($fail) { Write-Host "$fail failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
