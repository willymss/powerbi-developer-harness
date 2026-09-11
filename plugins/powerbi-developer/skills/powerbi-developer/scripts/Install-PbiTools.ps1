<#
.SYNOPSIS
  Install, update or check the Power BI developer toolchain. Idempotent; never fails on optional tools.
.DESCRIPTION
  -Check (default) prints the status table. -Install / -Update perform:
    1. pbir (uv tool install / upgrade pbir-cli)        - required
    2. te CLI (Tabular Editor, CDN zip -> %LOCALAPPDATA%\Programs\te, User PATH)
    3. Node check (winget install only with -RepairNode)
    4. npm -g @microsoft/powerbi-desktop-bridge-cli + @microsoft/powerbi-report-authoring-cli
    5. npx cache prime for @microsoft/powerbi-modeling-mcp (the plugin's .mcp.json server)
    6. jq (winget) only with -WithJq - note: activates the pbip/pbi-desktop plugins' bash hooks
  Writes $CLAUDE_PLUGIN_DATA\tool-status.json (or %LOCALAPPDATA%\powerbi-developer\tool-status.json).
.EXAMPLE
  pwsh -File Install-PbiTools.ps1 -Install
  pwsh -File Install-PbiTools.ps1 -Update -SkipTe
#>
[CmdletBinding()]
param(
    [switch]$Check, [switch]$Install, [switch]$Update,
    [switch]$SkipNode, [switch]$SkipTe, [switch]$SkipNpm, [switch]$SkipMcp,
    [switch]$WithJq, [switch]$RepairNode, [switch]$Json
)
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
$doWork = $Install -or $Update
$McpVersion = '0.5.0-beta.13'
$DesktopCliVersion = '0.1.2'
$AuthorCliVersion = '0.1.4'
$log = New-Object System.Collections.Generic.List[string]
function L([string]$m) { $log.Add($m); if (-not $Json) { Write-Host $m } }
function Add-UserPath([string]$Dir) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $Dir) { [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ";$Dir"), 'User'); L "  added to User PATH: $Dir (new terminals only)" }
    if (($env:Path -split ';') -notcontains $Dir) { $env:Path = "$env:Path;$Dir" }
}
foreach ($d in @("$env:LOCALAPPDATA\Programs\te", "$env:APPDATA\npm")) { if (Test-Path -LiteralPath $d) { if (($env:Path -split ';') -notcontains $d) { $env:Path = "$env:Path;$d" } } }
function Has([string]$Name) { return [bool](Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue) }
$actions = @()

if ($doWork) {
    # 1. uv + pbir
    if (-not (Has 'uv')) {
        L "uv is missing. Install it first:  winget install astral-sh.uv   (then reopen the terminal)"
        $actions += 'uv: MISSING - winget install astral-sh.uv'
        if (-not (Has 'pbir')) { L 'pbir cannot be installed without uv. Aborting.'; exit 2 }
    } else {
        if (-not (Has 'pbir')) { L '-- installing pbir-cli'; uv tool install pbir-cli 2>&1 | ForEach-Object { L "  $_" }; $actions += 'pbir: installed' }
        elseif ($Update) { L '-- upgrading pbir-cli'; uv tool upgrade pbir-cli 2>&1 | ForEach-Object { L "  $_" }; $actions += 'pbir: upgraded' }
        else { $actions += 'pbir: present' }
    }
    # 2. te
    if (-not $SkipTe) {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        $dir = "$env:LOCALAPPDATA\Programs\te"
        $need = $Update -or -not (Test-Path -LiteralPath (Join-Path $dir 'te.exe'))
        if ($need) {
            L '-- installing/updating te (Tabular Editor CLI)'
            try {
                $url = "https://cdn.tabulareditor.com/files/cli/latest/te-win-$arch.zip"
                # CDN serves GET only (HEAD returns 404): probe with a ranged GET
                $probe = $null
                try { $probe = Invoke-WebRequest -Uri $url -Headers @{ Range = 'bytes=0-99' } -UseBasicParsing -TimeoutSec 20 } catch { $probe = $null }
                if (-not $probe) { throw "CDN not reachable: $url" }
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\te.zip" -UseBasicParsing -TimeoutSec 300
                Expand-Archive -Force "$env:TEMP\te.zip" -DestinationPath $dir
                Add-UserPath $dir
                $v = (& "$dir\te.exe" --version 2>&1 | Out-String)
                L "  te: $($v.Trim() -replace '\s+', ' ')"
                if ($v -match 'expires in (\d+) day') { L "  NOTE: te early preview expires in $($matches[1]) day(s); re-run -Update before then." }
                $actions += 'te: installed/updated'
            } catch { L "  te install failed: $($_.Exception.Message) - the cascade falls back to MCP -> TOM -> TMDL"; $actions += 'te: FAILED (optional)' }
        } else { Add-UserPath $dir; $actions += 'te: present' }
    }
    # 3. Node
    $nodeOk = Has 'node'
    if (-not $nodeOk -and -not $SkipNode) {
        if ($RepairNode) {
            L '-- installing Node LTS via winget'
            winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object { L "  $_" }
            $env:Path = "$env:Path;$env:ProgramFiles\nodejs"
            $nodeOk = Has 'node'
        } else {
            L 'Node is missing (managed devices may remove it). Run:  winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements   or re-run with -RepairNode.'
        }
        if (-not $nodeOk) { $actions += 'node: MISSING - npm tools and the modeling MCP are unavailable until repaired' }
    }
    # 4. npm CLIs
    if ($nodeOk -and -not $SkipNpm) {
        L '-- npm global CLIs (powerbi-desktop, powerbi-report-author)'
        New-Item -ItemType Directory -Force -Path "$env:APPDATA\npm" | Out-Null
        $pkgs = if ($Update) { '@microsoft/powerbi-desktop-bridge-cli@latest @microsoft/powerbi-report-authoring-cli@latest' } else { "@microsoft/powerbi-desktop-bridge-cli@$DesktopCliVersion @microsoft/powerbi-report-authoring-cli@$AuthorCliVersion" }
        cmd /d /c "npm install -g $pkgs" 2>&1 | ForEach-Object { L "  $_" }
        Add-UserPath "$env:APPDATA\npm"
        foreach ($t in 'powerbi-desktop', 'powerbi-report-author') {
            $v = (cmd /d /c "$t --version" 2>&1 | Out-String).Trim()
            L "  ${t}: $v"
        }
        $actions += 'npm CLIs: installed/updated'
    } elseif (-not $nodeOk) { $actions += 'npm CLIs: skipped (no Node)' }
    # 5. MCP prime
    if ($nodeOk -and -not $SkipMcp) {
        L "-- priming npx cache for @microsoft/powerbi-modeling-mcp@$McpVersion (up to 3 min)"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$env:ComSpec"; $psi.Arguments = "/d /c npx -y @microsoft/powerbi-modeling-mcp@$McpVersion --help"
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(180000)) { try { $p.Kill($true) } catch {}; L '  npx prime timed out'; $actions += 'mcp: prime TIMED OUT' }
        else { L "  npx exit $($p.ExitCode)"; $actions += $(if ($p.ExitCode -eq 0) { 'mcp: primed' } else { 'mcp: prime failed (check npm registry access)' }) }
    }
    # 6. jq
    if ($WithJq -and -not (Has 'jq')) {
        L '-- installing jq (activates the pbip and pbi-desktop plugin bash hooks)'
        winget install jqlang.jq --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object { L "  $_" }
        $actions += 'jq: installed'
    }
}

# status table (always)
$statusScript = Join-Path $PSScriptRoot 'Get-PbiToolStatus.ps1'
$dataRoot = if ($env:CLAUDE_PLUGIN_DATA) { $env:CLAUDE_PLUGIN_DATA } else { Join-Path $env:LOCALAPPDATA 'powerbi-developer' }
$save = Join-Path $dataRoot 'tool-status.json'
$rowsJson = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $statusScript -Json -Save $save
$rows = @()
try { $rows = @(($rowsJson -join '') | ConvertFrom-Json -Depth 6) } catch {}

$followups = @()
if ($doWork) { $followups += 'Open a NEW terminal (or restart Claude Code) so User PATH changes (te, npm) are visible.' }
$deskRow = $rows | Where-Object { $_.tool -eq 'pbir' } | Select-Object -First 1
$followups += "If 'pbir -q desktop status --json' says not_connected while Desktop is open: File > Options > Preview features > 'Enable external tool access to Power BI Desktop through secure local APIs', then restart Desktop."
$nodeRow = $rows | Where-Object { $_.tool -eq 'node' } | Select-Object -First 1
if ($nodeRow -and -not $nodeRow.present) { $followups += 'Node is absent: winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements (or -RepairNode).' }
if ($Update) { $followups += "If npm printed a newer powerbi-modeling-mcp, bump the pin in the plugin's .mcp.json (currently @$McpVersion)." }

if ($Json) {
    [Console]::Out.Write((@{ actions = $actions; tools = $rows; followups = $followups; log = $log } | ConvertTo-Json -Depth 6 -Compress))
} else {
    ''
    $rows | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize tool, present, version, path, note | Out-String -Width 220
    if ($actions.Count) { 'Actions:'; $actions | ForEach-Object { "  - $_" } }
    'Follow-ups:'; $followups | ForEach-Object { "  - $_" }
    "Status saved: $save"
}
exit 0
