<#
.SYNOPSIS
  Normalised Power BI Desktop bridge state (instances, open file, unsaved flag, pages).
.DESCRIPTION
  Source order: 1) fixture in $env:PBI_DEV_FAKE_DESKTOP_STATE (JSON; test seam),
  2) `pbir -q desktop status --json` (one retry), 3) the raw named pipe
  \\.\pipe\pbi-desktop-bridge-<pid> (JSON-RPC 2.0, Content-Length framing), so the
  hooks still work without pbir. The pipe client below is an independent
  implementation of that framing; the protocol itself is documented by the
  data-goblin pbi-desktop plugin (skills/connect-pbid/references/desktop-bridge.md).
  Always exits 0. Output shape:
  { status, source: pbir|pipe|fixture|none, instances:[{ pid, currentFilePath,
    hasUnsavedChanges, reportDir, status, pages:[{name, displayName}], manifest? }] }
.PARAMETER DesktopPid
  Only this PBIDesktop.exe process (alias -ProcessId). (-Pid is reserved by PowerShell.)
.PARAMETER ReportDir
  Only the instance whose open file lives beside this .Report / .pbip path.
.PARAMETER Manifest
  Also fetch bridge.manifest per instance (raw pipe only; pbir has no manifest command).
#>
[CmdletBinding()]
param(
    [Alias('ProcessId')][int]$DesktopPid = 0,
    [string]$ReportDir = '',
    [switch]$Manifest,
    [switch]$Json,
    [int]$TimeoutSec = 10
)
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
foreach ($d in @("$env:LOCALAPPDATA\Programs\te", "$env:APPDATA\npm")) {
    if ($d -and (Test-Path -LiteralPath $d) -and (($env:Path -split ';') -notcontains $d)) { $env:Path = "$env:Path;$d" }
}

function Invoke-Proc([string]$File, [string]$ArgList, [int]$Timeout) {
    $r = [ordered]@{ ok = $false; stdout = ''; stderr = ''; timed_out = $false }
    try {
        $exe = $File
        try { $exe = (Get-Command $File -ErrorAction Stop | Select-Object -First 1).Source } catch {}
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if ($exe -match '\.(cmd|bat)$') { $psi.FileName = "$env:ComSpec"; $psi.Arguments = "/d /c `"`"$exe`" $ArgList`"" }
        else { $psi.FileName = $exe; $psi.Arguments = $ArgList }
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($Timeout * 1000)) { $r.timed_out = $true; try { $p.Kill($true) } catch {} }
        try { $r.stdout = $o.GetAwaiter().GetResult() } catch {}
        try { $r.stderr = $e.GetAwaiter().GetResult() } catch {}
        $r.ok = (-not $r.timed_out) -and ($p.ExitCode -eq 0)
    } catch { $r.stderr = $_.Exception.Message }
    return $r
}

function Get-PagesFromDisk([string]$Dir) {
    $pages = @()
    try {
        $pagesJson = Join-Path $Dir 'definition\pages\pages.json'
        if (-not (Test-Path -LiteralPath $pagesJson)) { return @() }
        $order = (Get-Content -LiteralPath $pagesJson -Raw | ConvertFrom-Json).pageOrder
        foreach ($n in $order) {
            $pj = Join-Path $Dir "definition\pages\$n\page.json"
            $dn = $n
            if (Test-Path -LiteralPath $pj) { try { $dn = (Get-Content -LiteralPath $pj -Raw | ConvertFrom-Json).displayName } catch {} }
            $pages += [ordered]@{ name = $n; displayName = $dn }
        }
    } catch {}
    return $pages
}
function Get-ReportDirFromFile([string]$File) {
    if (-not $File) { return '' }
    try {
        $dir = Split-Path $File -Parent
        $base = [IO.Path]::GetFileNameWithoutExtension($File)
        $cand = Join-Path $dir "$base.Report"
        if (Test-Path -LiteralPath $cand) { return $cand }
        return $cand
    } catch { return '' }
}
function New-Instance($ProcId, $File, $Unsaved, $Dir, $Status, $Pages, $ManifestObj) {
    $o = [ordered]@{
        pid = [int]$ProcId; currentFilePath = [string]$File; hasUnsavedChanges = [bool]$Unsaved
        reportDir = [string]$Dir; status = [string]$Status; pages = @($Pages | Where-Object { $null -ne $_ })
    }
    if ($ManifestObj) { $o.manifest = $ManifestObj }
    return $o
}

# ---- 1. fixture ----
$result = $null
if ($env:PBI_DEV_FAKE_DESKTOP_STATE) {
    try {
        $fx = $env:PBI_DEV_FAKE_DESKTOP_STATE | ConvertFrom-Json -Depth 20
        $inst = @()
        foreach ($i in @($fx.instances)) {
            $dir = if ($i.reportDir) { $i.reportDir } else { Get-ReportDirFromFile $i.currentFilePath }
            $pg = if ($i.pages) { @($i.pages | ForEach-Object { [ordered]@{ name = $_.name; displayName = $_.displayName } }) } else { @() }
            $inst += New-Instance $i.pid $i.currentFilePath $i.hasUnsavedChanges $dir ($(if ($i.status) { $i.status } else { 'ready' })) $pg $null
        }
        $status = if ($fx.status) { $fx.status } elseif ($inst.Count) { 'connected' } else { 'not_connected' }
        $result = [ordered]@{ status = $status; source = 'fixture'; instances = $inst }
    } catch { $result = [ordered]@{ status = 'error'; source = 'fixture'; error = $_.Exception.Message; instances = @() } }
}

# ---- 2. pbir ----
if (-not $result) {
    $pbir = $null
    try { $pbir = (Get-Command pbir -ErrorAction Stop | Select-Object -First 1).Source } catch {}
    if ($pbir) {
        $argList = "-q desktop status --json"
        if ($DesktopPid -gt 0) { $argList += " --pid $DesktopPid" }
        $r = Invoke-Proc 'pbir' $argList $TimeoutSec
        if (-not $r.stdout -and -not $r.timed_out) { Start-Sleep -Milliseconds 500; $r = Invoke-Proc 'pbir' $argList $TimeoutSec }
        if ($r.stdout) {
            try {
                $j = $r.stdout | ConvertFrom-Json -Depth 20
                $inst = @()
                foreach ($i in @($j.instances)) {
                    $dir = if ($i.reportDir) { $i.reportDir } else { Get-ReportDirFromFile $i.currentFilePath }
                    $pg = @()
                    if ($i.pages) { $pg = @($i.pages | ForEach-Object { [ordered]@{ name = $_.name; displayName = $_.displayName } }) }
                    elseif ($dir) { $pg = Get-PagesFromDisk $dir }
                    $inst += New-Instance $i.pid $i.currentFilePath $i.hasUnsavedChanges $dir ($(if ($i.status) { $i.status } else { 'ready' })) $pg $null
                }
                $result = [ordered]@{ status = [string]$j.status; source = 'pbir'; instances = $inst }
            } catch {}
        }
    }
}

# ---- 3. raw named pipe ----
# Each message is "Content-Length: <n>\r\n\r\n" followed by <n> bytes of UTF-8 JSON (the
# LSP base-protocol framing). Pipes do not support ReadTimeout, so reads go through
# ReadAsync with a deadline.
function Receive-PipeChunk([System.IO.Stream]$Stream, [byte[]]$Buffer, [int]$Offset, [int]$Count, [int]$TimeoutMs) {
    $task = $Stream.ReadAsync($Buffer, $Offset, $Count)
    if (-not $task.Wait($TimeoutMs)) { throw 'bridge pipe read timed out' }
    if ($task.Result -le 0) { throw 'bridge pipe closed' }
    return $task.Result
}
function Receive-BridgeMessage([System.IO.Stream]$Stream, [int]$TimeoutMs) {
    $head = [System.Collections.Generic.List[byte]]::new()
    $one = [byte[]]::new(1)
    while (-not ($head.Count -ge 4 -and $head[$head.Count - 4] -eq 13 -and $head[$head.Count - 3] -eq 10 -and
                 $head[$head.Count - 2] -eq 13 -and $head[$head.Count - 1] -eq 10)) {
        if ($head.Count -gt 8192) { throw 'bridge header too long' }
        [void](Receive-PipeChunk $Stream $one 0 1 $TimeoutMs)
        $head.Add($one[0])
    }
    $size = -1
    foreach ($line in ([Text.Encoding]::ASCII.GetString($head.ToArray()) -split "`r`n")) {
        $kv = $line -split ':', 2
        if ($kv.Count -eq 2 -and $kv[0].Trim() -ieq 'Content-Length') { $size = [int]$kv[1].Trim() }
    }
    if ($size -lt 0) { throw 'bridge message has no Content-Length' }
    $body = [byte[]]::new($size)
    $got = 0
    while ($got -lt $size) { $got += Receive-PipeChunk $Stream $body $got ($size - $got) $TimeoutMs }
    return ([Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json -Depth 20)
}
function Send-BridgeRequest([System.IO.Stream]$Stream, [int]$Id, [string]$Method, $Params, [int]$TimeoutMs) {
    $payload = [ordered]@{ jsonrpc = '2.0'; id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 10
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $frame = [byte[]]([Text.Encoding]::ASCII.GetBytes("Content-Length: $($bytes.Length)`r`n`r`n") + $bytes)
    $Stream.Write($frame, 0, $frame.Length)
    $Stream.Flush()
    # skip notifications or stale replies until the response with our id arrives
    for ($n = 0; $n -lt 32; $n++) {
        $msg = Receive-BridgeMessage $Stream $TimeoutMs
        if ($null -ne $msg.id -and [int]$msg.id -eq $Id) { return $msg }
    }
    throw "no reply to $Method"
}
if (-not $result -or ($result.status -ne 'connected' -and $Manifest)) {
    $pids = @()
    try { $pids = [System.IO.Directory]::GetFiles("\\.\pipe\") | ForEach-Object { if ($_ -match 'pbi-desktop-bridge-(\d+)$') { [int]$matches[1] } } } catch {}
    if ($DesktopPid -gt 0) { $pids = @($pids | Where-Object { $_ -eq $DesktopPid }) }
    $inst = @()
    foreach ($procId in $pids) {
        $pipe = $null
        try {
            $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', "pbi-desktop-bridge-$procId",
                [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
            $pipe.Connect([Math]::Max(1000, $TimeoutSec * 500))
            $ms = $TimeoutSec * 1000
            $man = $null
            try { $man = (Send-BridgeRequest $pipe 1 'bridge.manifest' @{} $ms).result } catch {}
            $st = (Send-BridgeRequest $pipe 2 'application.state.get/v1' @{} $ms).result
            $dir = Get-ReportDirFromFile $st.currentFilePath
            $inst += New-Instance $procId $st.currentFilePath $st.hasUnsavedChanges $dir 'ready' (Get-PagesFromDisk $dir) ($(if ($Manifest) { $man } else { $null }))
        } catch {
            $inst += New-Instance $procId '' $false '' "error: $($_.Exception.Message)" @() $null
        } finally { if ($pipe) { $pipe.Dispose() } }
    }
    if ($inst.Count -gt 0) { $result = [ordered]@{ status = 'connected'; source = 'pipe'; instances = $inst } }
    elseif (-not $result) { $result = [ordered]@{ status = 'not_connected'; source = 'none'; instances = @() } }
}

# ---- filters ----
if ($DesktopPid -gt 0) { $result.instances = @($result.instances | Where-Object { $_.pid -eq $DesktopPid }) }
if ($ReportDir) {
    $want = ($ReportDir -replace '/', '\').TrimEnd('\')
    $wantDir = if ($want -match '(?i)\.(report|pbip)$') { Split-Path $want -Parent } else { $want }
    $result.instances = @($result.instances | Where-Object {
        $d = [string]$_.reportDir; $f = [string]$_.currentFilePath
        ($d -and ($d.TrimEnd('\') -ieq $want)) -or ($f -and ((Split-Path $f -Parent) -ieq $wantDir)) -or ($d -and ((Split-Path $d -Parent) -ieq $wantDir))
    })
}
if ($result.instances.Count -eq 0 -and $result.status -eq 'connected') { $result.status = 'no_match' }

if ($Json) { [Console]::Out.Write(($result | ConvertTo-Json -Depth 20 -Compress)) }
else {
    "Desktop: $($result.status) (source: $($result.source))"
    foreach ($i in $result.instances) {
        "  PID $($i.pid)  unsaved=$($i.hasUnsavedChanges)  $($i.currentFilePath)"
        "     reportDir: $($i.reportDir)  pages: $(@($i.pages).Count)"
    }
}
exit 0
