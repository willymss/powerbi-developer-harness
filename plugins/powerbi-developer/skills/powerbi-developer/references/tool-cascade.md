# Tool cascade

Six jobs, each with an ordered list of tools. The SessionStart banner tells you which tier is
available; the first command in each row is the health probe that selects the tier. Never block on
a Node-based tool (managed devices may remove Node): skip silently and use the next tier.

| Job | 1st | 2nd | 3rd | 4th |
|---|---|---|---|---|
| **Model write** (measure, column, relationship, RLS, calc group) | `te` CLI: `te add/set/move/remove ... -m <model> --save` (probe `te --version`; preview expiry in the banner) | powerbi-modeling-mcp tools `mcp__plugin_powerbi-developer_powerbi-modeling-mcp__*` (probe: `list_tables`) | TOM via `pbi-desktop:connect-pbid` under **powershell.exe 5.1** (probe: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<connect-pbid>\scripts\connect-and-enumerate.ps1"`) | `pbip:tmdl` skill (edit TMDL on disk, then `te validate`) |
| **Model read / DAX query** | `te list/get -m <model> --output-format json`, `te query -q "<DAX>" --local` | MCP `list_*`/`get_*`/`execute_dax` | `pbir -q model "<r>" -d -F json`, `pbir -q model "<r>" -q "<DAX>" -F json` (thick reports need ADOMD) | TOM / ADOMD scripts (PS 5.1) |
| **Report write** | `pbir` only: `set/add/visuals/pages/filters/bookmarks/dax/theme` or `batch` (validated, no BOM) | - (no second tier: if pbir lacks the op, stop and report the gap) | | |
| **Desktop drive** (state, reload, screenshot) | `pbir -q desktop status/refresh/screenshot --json` | `powerbi-desktop status/manifest/reload/screenshot-all --pid` (npm) | raw named pipe (`Get-PbiDesktopState.ps1 -Manifest`; protocol documented in `connect-pbid\references\desktop-bridge.md`) | validate-only; with permission publish to a sandbox workspace and inspect in the browser |
| **Validate** | `pbir -q validate "<r>" --all --json` + `pbir -q bpa run "<r>" -o json` | `powerbi-report-author validate "<.Report>"` (second opinion, remote schema) | `pbip:pbip-validator` agent (structure + rename cascade) | `te validate -m <model>` for the model side |
| **Publish / govern** | `pbir -q publish "<r>" "<WS>.Workspace/<Report>.Report" -f` (hook asks) | `fab` CLI via `fabric-cli:fabric-cli` (auth `fab auth status`) | `az rest` against the Fabric REST API | - |

## Degradation rules

- **Node absent** -> MCP and both Microsoft CLIs are unavailable. Say so once; do not retry.
- **`te` absent or expired** (preview builds expire; the banner shows the date) -> MCP -> TOM -> TMDL. Re-run `/powerbi-developer:setup -Update` to refresh te.
- **Bridge absent** (`not_connected` twice, a few seconds apart) -> relay the preview-feature steps once
  (File > Options > Preview features > *Enable external tool access to Power BI Desktop through secure local APIs*, restart Desktop), then validate-only. Say explicitly that rendering was not verified.
- **ADOMD absent** -> `pbir model -q` on thick reports fails; use `te query --local` or TOM.
- **Model is Desktop-only** (no PBIP on disk, no te/MCP/TOM path) -> stop and tell the user; do not improvise.
- **`pbir desktop` returns `Cancelled`/`Timeout`** after one retry -> `powerbi-desktop manifest --pid` to probe capabilities, then `powerbi-desktop reload/screenshot-all --pid`.

## Handoff rules that apply at every tier

- After any **live** model write (TOM, MCP) write the same change to TMDL in the same turn; after any **disk** write (te, tmdl) let Desktop apply it via its own prompt, never via a forced refresh while unsaved. Both stores must agree before the turn ends.
- `te validate` after every model change; live DAX check (`te query` / `pbir model -q`) for anything a visual binds.
- Report JSON is written by pbir only; model JSON/TMDL by the cascade above; nothing by hand unless the hook's ask is answered yes.
