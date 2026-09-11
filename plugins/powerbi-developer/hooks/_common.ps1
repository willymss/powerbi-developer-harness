# _common.ps1 - shared helpers for powerbi-developer hooks. Dot-source, never run.
# Contract: every hook self-gates (exit 0 fast when not applicable), never throws,
# honours POWERBI_DEVELOPER_HOOKS=off and per-gate toggles in $CLAUDE_PLUGIN_DATA\config.json.
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
try { [Console]::InputEncoding  = [Text.UTF8Encoding]::new($false) } catch {}

$script:PluginRoot = if ($env:CLAUDE_PLUGIN_ROOT) { $env:CLAUDE_PLUGIN_ROOT } else { Split-Path $PSScriptRoot -Parent }
$script:ScriptsDir = Join-Path $script:PluginRoot 'skills\powerbi-developer\scripts'

function Add-KnownToolPaths {
    # User PATH changes (te, npm -g) only reach Claude Code after a restart; bridge the gap.
    foreach ($d in @("$env:LOCALAPPDATA\Programs\te", "$env:APPDATA\npm", "$env:USERPROFILE\.local\bin")) {
        if ($d -and (Test-Path -LiteralPath $d) -and (($env:Path -split ';') -notcontains $d)) { $env:Path = "$env:Path;$d" }
    }
}
Add-KnownToolPaths

function Read-HookInput {
    try {
        $raw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -Depth 30)
    } catch { return $null }
}

function Get-PluginDataRoot {
    if ($env:CLAUDE_PLUGIN_DATA) { return $env:CLAUDE_PLUGIN_DATA }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'powerbi-developer') }
    return $null
}
function Get-PluginDataPath([string]$Leaf) {
    $root = Get-PluginDataRoot
    if (-not $root) { return $null }
    try { New-Item -ItemType Directory -Force -Path $root -ErrorAction SilentlyContinue | Out-Null } catch {}
    return (Join-Path $root $Leaf)
}

function Get-HookConfig {
    $cfg = [ordered]@{
        hand_edit_gate = $true; encoding_guard = $true; refresh_guard = $true; hazard_gate = $true
        ledger = $true; stop_gate = $true; ask_on_model_reload = $true
        require_screenshot = $true; require_review = $true; banner_max_lines = 25
    }
    if ($env:POWERBI_DEVELOPER_HOOKS -eq 'off') {
        foreach ($k in @($cfg.Keys)) { if ($cfg[$k] -is [bool]) { $cfg[$k] = $false } }
        return $cfg
    }
    $path = Get-PluginDataPath 'config.json'
    if ($path -and (Test-Path -LiteralPath $path)) {
        try {
            $user = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($p in $user.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch {}
    }
    return $cfg
}

function Write-Json($Object) {
    [Console]::Out.Write(($Object | ConvertTo-Json -Compress -Depth 8))
}
function Emit-Decision([string]$Event, [string]$Decision, [string]$Reason) {
    Write-Json @{ hookSpecificOutput = @{ hookEventName = $Event; permissionDecision = $Decision; permissionDecisionReason = $Reason } }
    exit 0
}
function Emit-Context([string]$Event, [string]$Text) {
    Write-Json @{ hookSpecificOutput = @{ hookEventName = $Event; additionalContext = $Text } }
    exit 0
}
function Block([string]$Reason) {
    [Console]::Error.Write($Reason)
    exit 2
}

function Get-CommandText($HookInput) {
    try { $c = $HookInput.tool_input.command; if ($c) { return [string]$c } } catch {}
    return ''
}
function Get-FilePathInput($HookInput) {
    try { $p = $HookInput.tool_input.file_path; if ($p) { return [string]$p } } catch {}
    return ''
}
function Normalize-Path([string]$Path) {
    if (-not $Path) { return '' }
    $p = $Path -replace '/', '\'
    if ($p -match '^\\\\\?\\') { $p = $p.Substring(4) }
    return $p
}
function Test-OneDrivePath([string]$Path) {
    return ($Path -match '(?i)\\OneDrive')
}
function Test-PbipArtifactPath([string]$Path) {
    $p = Normalize-Path $Path
    if (-not $p) { return $false }
    if ($p -match '(?i)\\(_brief|_verify|screenshots|\.claude|evals)\\') { return $false }
    return ($p -match '(?i)\\[^\\]+\.report\\.*\.(json|pbir)$' -or
            $p -match '(?i)\\[^\\]+\.semanticmodel\\.*\.tmdl$' -or
            $p -match '(?i)\.pbip$' -or $p -match '(?i)\\\.platform$' -or $p -match '(?i)\\\.pbi\\')
}

# ---------- ledger ----------
function Get-LedgerPath([string]$SessionId) {
    $root = Get-PluginDataPath 'sessions'
    if (-not $root) { return $null }
    try { New-Item -ItemType Directory -Force -Path $root -ErrorAction SilentlyContinue | Out-Null } catch {}
    $sid = [string]$SessionId
    $sid = $sid -replace '[^\w\-\.]', '_'
    if (-not $sid) { $sid = 'unknown' }
    return (Join-Path $root "$sid.jsonl")
}
function Add-Ledger($HookInput, [string]$Kind, [string]$Detail, [bool]$Ok = $true, [hashtable]$Extra = $null) {
    try {
        $cfg = Get-HookConfig
        if (-not $cfg.ledger) { return }
        $path = Get-LedgerPath ([string]$HookInput.session_id)
        if (-not $path) { return }
        if ($Detail -and $Detail.Length -gt 200) { $Detail = $Detail.Substring(0, 200) }
        $rec = [ordered]@{
            ts = (Get-Date).ToString('o'); session_id = [string]$HookInput.session_id
            event = [string]$HookInput.hook_event_name; tool = [string]$HookInput.tool_name
            kind = $Kind; detail = $Detail; ok = $Ok
        }
        if ($Extra) { foreach ($k in $Extra.Keys) { $rec[$k] = $Extra[$k] } }
        $line = ($rec | ConvertTo-Json -Compress -Depth 6) + "`n"
        $enc = [Text.UTF8Encoding]::new($false)
        for ($i = 0; $i -lt 5; $i++) {
            try { [IO.File]::AppendAllText($path, $line, $enc); break } catch [System.IO.IOException] { Start-Sleep -Milliseconds 60 }
        }
    } catch {}
}
function Read-Ledger([string]$SessionId) {
    $out = @()
    try {
        $path = Get-LedgerPath $SessionId
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $out += ($line | ConvertFrom-Json) } catch {}
        }
    } catch {}
    return $out
}
function Remove-OldLedgers([int]$Days = 14) {
    try {
        $root = Get-PluginDataPath 'sessions'
        if ($root -and (Test-Path -LiteralPath $root)) {
            Get-ChildItem -LiteralPath $root -Filter '*.jsonl' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Days) } | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# ---------- process helpers ----------
function Invoke-ProcessWithTimeout([string]$FilePath, [string]$Arguments, [int]$TimeoutSec = 10, [string]$WorkingDirectory = $null) {
    $res = [ordered]@{ ok = $false; exit = -1; stdout = ''; stderr = ''; timed_out = $false }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $resolved = $null
        try { $resolved = (Get-Command $FilePath -ErrorAction Stop | Select-Object -First 1).Source } catch {}
        $psi.FileName = if ($resolved) { $resolved } else { $FilePath }
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit([int]($TimeoutSec * 1000))) {
            $res.timed_out = $true
            try { $p.Kill($true) } catch {}
        }
        try { $res.stdout = $outTask.GetAwaiter().GetResult() } catch {}
        try { $res.stderr = $errTask.GetAwaiter().GetResult() } catch {}
        if (-not $res.timed_out) { $res.exit = $p.ExitCode; $res.ok = ($p.ExitCode -eq 0) }
    } catch { $res.stderr = "$($_.Exception.Message)" }
    return $res
}
function Get-DesktopState([int]$TimeoutSec = 12) {
    $script = Join-Path $script:ScriptsDir 'Get-PbiDesktopState.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return $null }
    $r = Invoke-ProcessWithTimeout -FilePath 'pwsh' -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Json -TimeoutSec $([Math]::Max(2, $TimeoutSec - 2))" -TimeoutSec $TimeoutSec
    if ($r.stdout) { try { return ($r.stdout | ConvertFrom-Json -Depth 20) } catch {} }
    return $null
}

# ---------- classification of shell commands (shared by post-command and tests) ----------
function Get-CommandKinds([string]$Cmd) {
    # Returns a list of ledger kinds implied by a shell command line (may be empty).
    $kinds = New-Object System.Collections.Generic.List[string]
    if (-not $Cmd) { return $kinds }
    $c = $Cmd
    $isPbir = ($c -match '(?im)(^|[\s;&|(])pbir(\.exe)?\s')
    if ($isPbir) {
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\s(validate)\b' -and $c -notmatch '(?i)\bbatch\s+validate\b') { $kinds.Add('validate') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\sbpa\s+run\b' -and $c -notmatch '(?i)--fix') { $kinds.Add('validate') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\sbpa\s+run\b.*--fix.*--save') { $kinds.Add('mutation_report') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\sdesktop\s+(refresh|reload)\b') { $kinds.Add('refresh') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\sdesktop\s+screenshot\b') { $kinds.Add('screenshot') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\spublish\b') { $kinds.Add('publish') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\sbackup\b' -and $c -notmatch '(?i)--list|\s-l\b|--prune') { $kinds.Add('backup') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\s(set|add|mv|cp|rm|restore)\s') { $kinds.Add('mutation_report') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\sreport\s+(rename|rebind|convert|merge|split)') { $kinds.Add('mutation_report') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\sschema\s+upgrade\b') { $kinds.Add('mutation_report') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\s(visuals|pages|filters|bookmarks|annotations)\s+\w' -and
            $c -notmatch '(?i)\s(visuals|pages|filters|bookmarks|annotations)\s+(list|ls|json|show|find|audit|get)\b' -and
            $c -notmatch '(?i)--show\b|--list\b|--dry-run\b|\s-l\b|\s-s\b') { $kinds.Add('mutation_report') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\sdax\s+measures?\s+(add|set|update|rename|rm|remove|clear)') { $kinds.Add('mutation_report') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\sfields\s+(replace|replace-table|rename|add)\b' -and $c -notmatch '(?i)--dry-run') { $kinds.Add('mutation_report') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\sbatch\s+run\b' -and $c -notmatch '(?i)--dry-run') { $kinds.Add('mutation_report') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\stheme\s+(set-|apply|push|build|serialize|rename|icons|create-template)') { $kinds.Add('mutation_theme') }
        if ($c -match '(?i)\bpbir\b[^\n;|&]*\scolor\s+replace\b' -or $c -match '(?i)\bpbir\b[^\n;|&]*\sfonts\s+(replace|clear)\b') { $kinds.Add('mutation_theme') }
    }
    if ($c -match '(?i)\bpowerbi-desktop(\.cmd|\.exe)?\s+reload\b') { $kinds.Add('refresh') }
    if ($c -match '(?i)\bpowerbi-desktop(\.cmd|\.exe)?\s+screenshot') { $kinds.Add('screenshot') }
    if ($c -match '(?i)\bpowerbi-report-author(\.cmd|\.exe)?\s+validate\b') { $kinds.Add('validate') }
    if ($c -match '(?i)(^|[\s;&|(])te(\.exe)?\s[^\n;|&]*\b(validate|bpa\s+run)\b') { $kinds.Add('validate') }
    if ($c -match '(?i)(^|[\s;&|(])te(\.exe)?\s[^\n;|&]*(--save\b|\sdeploy\b)') { $kinds.Add('mutation_model') }
    if ($c -match '(?i)\.SaveChanges\s*\(') { $kinds.Add('mutation_model') }
    if ($c -match '(?i)Invoke-VerifyLoop') { $kinds.Add('verify_loop') }
    if ($c -match '(?i)report\.snapshot\.capture') { $kinds.Add('screenshot') }
    if ($c -match '(?i)file\.reload') { $kinds.Add('refresh') }
    return $kinds
}

function Get-FileTokens([string]$Cmd) {
    # Quoted or bare tokens that look like file paths of PBIP artefacts.
    $tokens = New-Object System.Collections.Generic.List[string]
    if (-not $Cmd) { return $tokens }
    foreach ($m in [regex]::Matches($Cmd, '"([^"\r\n]+?\.(tmdl|json|pbir|pbip|platform))"')) { $tokens.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($Cmd, "'([^'\r\n]+?\.(tmdl|json|pbir|pbip|platform))'")) { $tokens.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($Cmd, '(?<![\w"''])([A-Za-z]:[\\/][^\s"''<>|]+?\.(tmdl|json|pbir|pbip|platform))(?![\w"''])')) { $tokens.Add($m.Groups[1].Value) }
    return @($tokens | Select-Object -Unique)
}
