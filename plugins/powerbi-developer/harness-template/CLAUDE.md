# <Project name>

Power BI development with the `powerbi-developer` plugin. PBIP projects live under
`%PBI_PROJECTS_ROOT%\<name>` (default `C:\dev\pbi`), never in a OneDrive / SharePoint synced folder
(Microsoft does not support PBIP there; the sync marks directories ReadOnly and breaks `pbir rm/cp/restore`).

## Where things are

- Plugin: `powerbi-developer` (skill `/powerbi-developer`, setup `/powerbi-developer:setup`, agents
  `powerbi-developer`, `pbi-visual-reviewer`, `pbi-spec-verifier`). Installed from the
  `powerbi-developer-harness` marketplace, or loaded from a local clone via `~/.claude/skills/`.
- data-goblin plugins (`reports`, `pbip`, `semantic-models`, `pbi-desktop`, `tabular-editor`, `fabric-cli`):
  `~/.claude/plugins/cache/power-bi-agentic-development/<plugin>/<version>/`.
- Reports in this project: `<list the .pbip files and what Desktop normally has open>`.
- Sandbox for smoke tests (optional): a git-baselined copy of a report under `C:\dev\pbi-sandbox\`.

## How to work here

1. Read the `[powerbi-developer]` SessionStart banner first (tools, Desktop instances, unsaved flag, active pbir profile).
2. Plan into `<project>\_brief\` (notes, model inventory, `report-spec.md`), verify into `<project>\_verify\<ts>\`.
3. Run plugin `.ps1` files through the PowerShell tool (`pwsh -NoProfile -File ...`); Python through `uv run`.
4. PBIP text is UTF-8 without BOM + CRLF. Only `pbir` writes report JSON; models go through te -> MCP -> TOM (Windows PowerShell 5.1) -> tmdl.
5. Never hand-edit `report.json`, `mobileState.json`, `*DiagramLayout.json`, `.pbi\*`.
6. Check `hasUnsavedChanges` before any canvas refresh. Ask before commit, publish, `rm`, `restore`, `clear-formatting`.

## Harness

- Hooks (Guarded mode):
  - SessionStart -> toolchain + Desktop banner (`session-start.ps1`).
  - PreToolUse Edit|Write -> `guard-hand-edit.ps1`: deny undocumented files, ask for other PBIP files / TMDL / themes.
  - PreToolUse Bash|PowerShell -> `guard-command.ps1`: deny canvas refresh while Desktop is unsaved, ask on model re-apply, ask before pbir publish/rm/restore/cp visual/clear-formatting/`--rawdog`/`bpa --fix --save`/fields replace, te `--save`/deploy, TOM `SaveChanges`, MCP `--skipconfirmation`, destructive git.
  - PostToolUse Edit|Write / Bash|PowerShell -> `post-edit.ps1` / `post-command.ps1`: strip BOM + CRLF (exit 2 so you see it), JSON parse, evidence ledger.
  - PostToolUse Read(*.png) / MCP tools, SubagentStop reviewers -> `ledger.ps1`.
  - Stop -> `stop-gate.ps1`: blocks once per stop until mutations are validated, screenshotted (when Desktop is available) and reviewed.
- Kill switch: `POWERBI_DEVELOPER_HOOKS=off`; per-gate toggles in `$CLAUDE_PLUGIN_DATA\config.json` (fallback `%LOCALAPPDATA%\powerbi-developer\config.json`).
- Permissions (`.claude\settings.json`): pbir / uv / te / Microsoft CLIs / plugin scripts / read-only git allowed; publish, `te --save`, commits, installs ask; `git reset --hard`, force push, `pbir --rawdog` denied. Env: `PBIR_DESKTOP_AUTO_REFRESH=0`, `PBI_PROJECTS_ROOT`.
- Node missing (managed devices may remove it): the banner shows npm tools missing; `.mcp.json` fails soft; run `/powerbi-developer:setup -RepairNode` (winget) then restart Claude Code.
- Token budget: keep `_brief` files short; the skill loads ~5k tokens; references load on demand.
