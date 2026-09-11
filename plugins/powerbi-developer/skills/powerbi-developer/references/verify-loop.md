# Verify loop

A change is not done until it has been validated, rendered by Power BI Desktop, captured, and
looked at by someone who did not make it. The Stop hook enforces the order below through the
evidence ledger; this page is the procedure.

## Procedure (serial per Desktop PID)

1. **Validate**: `pbir -q validate "<r>" --all --json` (+ `te validate -m "<m>"` for model changes). Errors -> fix first.
2. **State**: `pbir -q desktop status --json` -> pick the PID whose `currentFilePath` is this project. Note `hasUnsavedChanges`.
3. **Refresh (guarded)**: only when `hasUnsavedChanges` is false. `Invoke-VerifyLoop.ps1` does this check itself; a manual
   `pbir -q desktop refresh "<r>" --pid <pid>` is denied by the hook while unsaved. Theme changes are NOT picked up by a refresh
   (Desktop caches themes by file name): close and reopen Desktop, or rename the theme.
4. **Screenshots**: `Invoke-VerifyLoop.ps1 -Report "<r>" -DesktopPid <pid> [-Pages ...] -Scale 2 -Settle 800` -> `_verify\<ts>\pages\*.png` + `manifest.json`.
   The filter pane is part of the page capture; review it too.
5. **Independent review**: dispatch `pbi-visual-reviewer` with the manifest path and a one-paragraph note: what changed, what
   should now be visible, what must not have changed. It returns issue / location / severity / fix.
6. **Spec diff (builds)**: dispatch `pbi-spec-verifier` with `_brief\build.layout.json` and `<r>`.
7. **Fix** with `pbir` commands (or contract changes), then repeat from 1. Stop when the reviewer reports no critical finding.

## Fallback table

| Situation | Do |
|---|---|
| `pbir desktop` returns an error / `Cancelled` / `Timeout` twice | `powerbi-desktop status`, `powerbi-desktop manifest --pid <pid>` (capability probe), `powerbi-desktop reload --pid <pid>`, `powerbi-desktop screenshot-all --pid <pid> --output-dir <dir>` (the verify loop does this automatically) |
| Both CLIs absent (Node removed) | raw pipe: `Get-PbiDesktopState.ps1 -Manifest -Json` for state; reload/snapshot per `pbi-desktop\...\connect-pbid\references\desktop-bridge.md` |
| `not_connected` twice, a few seconds apart | relay once: File > Options > Preview features > *Enable external tool access to Power BI Desktop through secure local APIs*, restart Desktop. Then validate-only; with permission publish to a **sandbox** workspace and inspect in the browser |
| `hasUnsavedChanges: true` | stop; ask the user to Save or discard in Desktop; do not refresh; say so in the summary |
| Screenshot is blank / spinner | increase `-Settle` (2000-4000 ms) and re-run; DirectQuery pages can take seconds |

## Screenshot review checklist (merged from Microsoft's screenshot-review and the design quality gate)

Adapted from microsoft/skills-for-fabric (MIT); see THIRD_PARTY_NOTICES.md in the repo root.

- Layout: visuals inside the canvas; no overlaps; aligned to the contract's boxes (`_brief\build.layout.json`); consistent gutters.
- Text: titles readable, no truncation/ellipsis, no default "Sum of X" titles when the contract names them; axis labels not rotated 90 degrees.
- Data: values plausible (not all blank, not all zero); cards show a formatted number; slicers show the expected field; sort order matches `sort_policy`.
- Colour: only `color_map` colours for series; negative/positive semantics respected; contrast >= 4.5:1 for text.
- Filter pane: intended filters present and not accidentally hidden/locked; nothing unexpected.
- Interaction (when screenshots of states exist): bookmarks/buttons still target the right visuals.
- Regression: pages that were not in scope look identical to their previous capture.

## Output shape

```yaml
verdict: pass | fail          # fail on any critical
findings:
  - issue: "Card 'kpi_var' shows (Blank)"
    location: "Executive Summary / kpi_var"
    severity: critical | warning | suggestion
    fix: 'pbir -q visuals bind "<r>/Executive Summary.Page/kpi_var.Visual" -a "Data:fact_sales.Variance"'
```

## Honesty

Screenshots prove rendering at one moment with one filter state. They do not prove numbers. Say
what was verified (validate clean, N pages captured, reviewer verdict) and what was not (unsaved
Desktop, bridge down, theme requires reopen). Never write "production-ready".
