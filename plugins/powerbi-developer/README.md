# powerbi-developer (Claude Code plugin)

Plan -> design contract -> approval -> `pbir batch` build -> validate -> guarded Desktop reload ->
screenshot -> independent review -> publish, for Power BI reports and semantic models on Windows.
It fuses Microsoft's *Power BI agentic* pipeline (planning / design / authoring skills, modeling MCP,
Desktop Bridge and report-authoring CLIs) with the data-goblin `power-bi-agentic-development` plugins
(`pbir` is the execution engine) and enforces the loop with hooks. It routes to existing skills; it
does not duplicate them.

## Install

From the `powerbi-developer-harness` marketplace (see the repo README for the full bootstrap):

```powershell
claude plugin marketplace add https://github.com/data-goblin/power-bi-agentic-development.git
claude plugin marketplace add https://github.com/willymss/powerbi-developer-harness.git
claude plugin install powerbi-developer@powerbi-developer-harness
```

The install pulls the six data-goblin plugins it routes to as dependencies. Then restart Claude Code
and run `/powerbi-developer:setup -Install` for the toolchain.

For development, a plugin folder under `~/.claude/skills/` loads in place as
`powerbi-developer@skills-dir`. Use one or the other on a machine, never both (hooks would run twice).

## Prerequisites

| Tool | Install | Required |
|---|---|---|
| Windows, Claude Code >= 2.1.259, PowerShell 7 (`pwsh`), uv, git | - | yes (every hook runs `pwsh`) |
| `pbir` (uv tool) | `uv tool install pbir-cli` | yes (0.9.31 tested) |
| data-goblin plugins `reports`, `pbip`, `semantic-models`, `pbi-desktop`, `tabular-editor`, `fabric-cli` | installed as dependencies | yes |
| Power BI Desktop with preview *Enable external tool access to Power BI Desktop through secure local APIs* | - | for reload/screenshots |
| `te` (Tabular Editor CLI) | `/powerbi-developer:setup -Install` (CDN zip; preview builds expire, the banner warns) | optional (1st model tier) |
| Node 20+ -> `@microsoft/powerbi-desktop-bridge-cli@0.1.2`, `@microsoft/powerbi-report-authoring-cli@0.1.4`, `@microsoft/powerbi-modeling-mcp@0.5.0-beta.13` | `/powerbi-developer:setup -Install` | optional (managed devices may remove Node; everything degrades to pbir-only) |
| Windows PowerShell 5.1 + TOM/ADOMD (`connect-pbid`) | ships with Windows | for the TOM tier |
| `jq` | `-WithJq` | optional; activates the pbip/pbi-desktop bash hooks |

## Components

| Path | What |
|---|---|
| `skills/powerbi-developer/SKILL.md` | the operating manual + router (phases, brownfield routing, cascade, approval gate, guardrails) |
| `skills/powerbi-developer/references/*.md` | pipeline, design-contract, verify-loop, tool-cascade, gotchas, publish |
| `skills/powerbi-developer/templates/` | `report-spec.template.md`, `design-brief.example.yaml` (compiler fixture) |
| `skills/powerbi-developer/scripts/` | `compile_brief_to_batch.py`, `verify_spec.py`, `build_model_inventory.py`, `Get-PbiDesktopState.ps1`, `Invoke-VerifyLoop.ps1`, `Test-Utf8NoBom.ps1`, `Get-PbiToolStatus.ps1`, `Install-PbiTools.ps1` |
| `skills/setup/SKILL.md` | `/powerbi-developer:setup [-Check|-Install|-Update ...]` |
| `agents/` | `powerbi-developer` (builder, phases 5-9), `pbi-visual-reviewer` (screenshots), `pbi-spec-verifier` (contract diff) |
| `hooks/` | Guarded harness (below) |
| `.mcp.json` | `powerbi-modeling-mcp` via `npx` (pinned; fails soft without Node) |
| `harness-template/` | `settings.json`, `CLAUDE.md`, `.gitignore` for a Power BI project folder |
| `evals/` | three cases for `claude plugin eval` (early access; need a local fixture, see `evals/README.md`) |

## Hooks (Guarded)

| Event | Script | Effect |
|---|---|---|
| SessionStart | `session-start.ps1` | toolchain + Desktop banner (<= 25 lines); evidence ledger opened |
| PreToolUse Edit/Write | `guard-hand-edit.ps1` | **deny** `report.json`, `mobileState.json`, `*DiagramLayout.json`, `.pbi\*`; **ask** themes, TMDL, other PBIP JSON |
| PreToolUse Bash/PowerShell | `guard-command.ps1` | **deny** canvas refresh while `hasUnsavedChanges`; **ask** on `-m`, raw `file.reload`, multi-instance without `--pid`; **ask** on publish / rm / restore / cp visual / clear-formatting / `--rawdog` / `bpa --fix --save` / fields replace / `te --save|deploy` / `SaveChanges` / MCP `--skipconfirmation` / destructive git |
| PostToolUse Edit/Write, Bash/PowerShell | `post-edit.ps1`, `post-command.ps1` | strip UTF-8 BOM + normalise CRLF (exit 2 so Claude sees it), JSON parse (when jq absent), ledger |
| PostToolUse Read(*.png), MCP tools; SubagentStop reviewers | `ledger.ps1` | review / model evidence |
| Stop | `stop-gate.ps1` | blocks once per stop until mutations were validated -> screenshotted (Desktop available) -> reviewed |

Bypasses: `POWERBI_DEVELOPER_HOOKS=off`; per-gate booleans in `$CLAUDE_PLUGIN_DATA\config.json`
(fallback `%LOCALAPPDATA%\powerbi-developer\config.json`): `hand_edit_gate, encoding_guard, refresh_guard,
hazard_gate, ledger, stop_gate, ask_on_model_reload, require_screenshot, require_review`. Test seam:
`PBI_DEV_FAKE_DESKTOP_STATE=<json>`. Each hook costs one `pwsh` start (about a second).

## Artefact chain

`_brief\notes.md` -> `_brief\model-inventory.json` -> `_brief\report-spec.md` (Design Brief YAML, APPROVED) ->
`compile_brief_to_batch.py` -> `build.layout.json` + `build.batch.json` + `build.pages.ps1` + `build.post.ps1` + `build.run.ps1` ->
`build.run.ps1 -DryRun` / `-SkipPages` -> `Invoke-VerifyLoop.ps1` -> `_verify\<ts>\manifest.json` + `pages\*.png` ->
`pbi-visual-reviewer` / `pbi-spec-verifier` findings.

## Known limits

- `pbir batch` resolves `root` only relative to the cwd; `build.run.ps1` handles it, hand-written specs must too.
- `pbir open <abs .Report>` resolves through the active profile and can open a different file; open PBIPs with
  `powerbi-desktop open <.pbip>` or `Start-Process`. Desktop also refuses a second file with the same name, so
  rename sandbox copies before opening them beside the original.
- `.`-prefixed tables (e.g. `.Measures`) cannot be bound through pbir; the compiler aborts on them.
- pbir's bundled schemas lag Desktop (visualContainer 2.10/2.12 vs 2.9): `SCHEMA_ERROR` on `spacing` properties is a
  false positive; use `--allow-download-schemas` for an authoritative pass.
- Theme changes need a Desktop reopen; a canvas refresh does not show them.
- `te` is an early preview with an expiry date; the cascade degrades to MCP -> TOM -> TMDL.

## Licences

MIT (see `LICENSE` in the repo root). Text adapted from microsoft/skills-for-fabric (MIT) and the credit for
the data-goblin plugins are in `THIRD_PARTY_NOTICES.md`. The plugin routes to the GPL-3.0 data-goblin plugins
without copying them. `pbir-cli` ships under its own non-commercial licence: confirm the terms for company use.
The Tabular Editor CLI and the Microsoft npm packages are preview software under their own terms.
