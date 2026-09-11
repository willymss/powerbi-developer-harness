<#
.SYNOPSIS
  Set up powerbi-developer on a Windows machine: add the two marketplaces and install the plugin.
.DESCRIPTION
  Idempotent. Adds data-goblin/power-bi-agentic-development (the plugins powerbi-developer routes to)
  and this repo as marketplaces, refreshes them if already present, then installs
  powerbi-developer@powerbi-developer-harness. Its six data-goblin dependencies are installed with it.
  Afterwards: enable auto-update for both marketplaces in /plugin -> Marketplaces, restart Claude Code,
  and run /powerbi-developer:setup -Install inside a session for the toolchain.

  Do not run this on a machine that loads the plugin from a local clone under ~/.claude/skills/
  (powerbi-developer@skills-dir): the hooks would run twice.
.PARAMETER Scope
  user (default), project or local.
#>
[CmdletBinding()]
param([ValidateSet('user', 'project', 'local')][string]$Scope = 'user')
$ErrorActionPreference = 'Stop'

foreach ($tool in 'claude', 'git', 'pwsh', 'uv') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not on PATH; install it first (see README)." }
}
if (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.claude\skills\powerbi-developer\.claude-plugin\plugin.json')) {
    throw 'powerbi-developer already loads from ~/.claude/skills (skills-dir dev copy); installing it from the marketplace too would duplicate every hook.'
}

$marketplaces = [ordered]@{
    'power-bi-agentic-development' = 'https://github.com/data-goblin/power-bi-agentic-development.git'
    'powerbi-developer-harness'    = 'https://github.com/willymss/powerbi-developer-harness.git'
}
$known = @()
try { $known = @(claude plugin marketplace list --json | ConvertFrom-Json | ForEach-Object { $_.name }) } catch {}

foreach ($name in $marketplaces.Keys) {
    if ($known -contains $name) {
        Write-Host "marketplace ${name}: present, refreshing"
        claude plugin marketplace update $name
    } else {
        Write-Host "marketplace ${name}: adding"
        claude plugin marketplace add $marketplaces[$name] --scope $Scope
    }
    if ($LASTEXITCODE) { throw "marketplace $name failed (exit $LASTEXITCODE)" }
}

Write-Host 'installing powerbi-developer@powerbi-developer-harness (+ data-goblin dependencies)'
claude plugin install powerbi-developer@powerbi-developer-harness --scope $Scope
if ($LASTEXITCODE) { throw "install failed (exit $LASTEXITCODE)" }

claude plugin list
Write-Host ''
Write-Host 'Next:'
Write-Host '  1. /plugin -> Marketplaces -> enable auto-update for both marketplaces (off by default for third-party ones).'
Write-Host '  2. Restart Claude Code; the [powerbi-developer] banner should appear once.'
Write-Host '  3. In a session: /powerbi-developer:setup -Install'
