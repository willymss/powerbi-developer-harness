---
name: setup
description: Install or update the Power BI developer toolchain (pbir via uv, Tabular Editor te CLI, powerbi-desktop and powerbi-report-author npm CLIs, powerbi-modeling-mcp npx cache, optional jq) and print a status table. Run when the SessionStart banner reports a missing tool.
disable-model-invocation: true
allowed-tools: PowerShell, Bash, Read
argument-hint: "[-Check | -Install | -Update] [-SkipNode] [-SkipTe] [-SkipNpm] [-SkipMcp] [-WithJq] [-RepairNode]"
---

# Power BI developer toolchain setup

Run the installer with the arguments the user passed (default `-Check`, which only prints the table):

```powershell
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/skills/powerbi-developer/scripts/Install-PbiTools.ps1" $ARGUMENTS
```

Use the PowerShell tool. `-Install` and `-Update` change the machine (uv tool, `%LOCALAPPDATA%\Programs\te`,
npm global packages under `%APPDATA%\npm`, User PATH), so run them only when the user asked for them.

Then:

1. Show the status table verbatim (tool, present, version, note).
2. List the follow-ups the script printed. The recurring ones:
   - a new terminal / Claude Code restart is needed before User PATH changes (te, npm) are visible;
   - Desktop bridge `not_connected` while Desktop is open = enable the preview feature
     *Enable external tool access to Power BI Desktop through secure local APIs* and restart Desktop;
   - Node missing = `winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements`
     (or re-run with `-RepairNode`); until then the modeling MCP and the two Microsoft CLIs are unavailable and
     the pbir-only path is used;
   - after `-Update`, if a newer `@microsoft/powerbi-modeling-mcp` exists, bump the pin in `.mcp.json` in the
     plugin's source repo (not in the installed copy under `~/.claude/plugins/cache`, which updates overwrite)
     and push; other machines pick it up on the next plugin update.
3. Finish with the live Desktop state:

```powershell
pbir -q desktop status --json
```

Do not install anything the user did not ask for; `-WithJq` also activates the bash hooks of the
`pbip` and `pbi-desktop` plugins (they no-op without jq).
