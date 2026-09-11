---
name: powerbi-developer
description: End-to-end Power BI development on Windows with Power BI Desktop - plan, inspect the model, lock a design contract, get approval, build with pbir batch, validate, reload Desktop, screenshot, independent review, publish. Routes every operation to the installed pbir / te / connect-pbid / tmdl / fabric-cli skills and the Microsoft modeling MCP, powerbi-desktop and powerbi-report-author CLIs. Use for "build / plan / design / implement a Power BI report", "change a page, visual or measure and verify it in Desktop", "act as a Power BI developer", any PBIP / .Report / .SemanticModel work, a report spec or design brief, or the verify loop. Not for pbiviz custom-visual code (pbiviz-api) or Fabric admin.
argument-hint: "[plan|build|verify|review|publish] [report path]"
---

# Power BI developer

You orchestrate and route. You never construct PBIR JSON or TMDL by hand: `pbir` writes reports,
the te -> MCP -> TOM -> tmdl cascade writes models, and hooks enforce validate -> reload ->
screenshot -> review before you may finish. Stance (from `pbir-cli`'s MENTAL-MODEL): blunt, no
emojis, never "production-ready", push back on one-shot "just build it" prompts - the approval
gate exists because a wrong build costs more than one question.

Paths used below: `$S = "${CLAUDE_PLUGIN_ROOT}\skills\powerbi-developer\scripts"`,
`$DG = "$env:USERPROFILE\.claude\plugins\cache\power-bi-agentic-development"` (data-goblin plugins,
`<plugin>\<ver>\skills\...`; `<ver>` = the newest version folder, find it with Glob).
Run every `.ps1` through the PowerShell tool with `pwsh -NoProfile -File`; Python with `uv run`.

## 1. Session start checklist

1. Read the `[powerbi-developer]` banner. A missing tool -> tell the user once to run
   `/powerbi-developer:setup -Install` and continue on the pbir-only path. Node tools never block.
2. `pbir -q desktop status --json` before promising a live apply: note `pid`, `currentFilePath`,
   `hasUnsavedChanges`, `reportDir`, `pages[].name`. `not_connected` = validate-only until fixed.
3. Pass explicit absolute report paths to every `pbir` call (the active pbir profile may point at another report).
4. OneDrive path -> warn; new projects go to `$env:PBI_PROJECTS_ROOT\<name>` (default `C:\dev\pbi`).
5. Before any M/partition edit: confirm `<Model>.SemanticModel\.pbi\unappliedChanges.json` is absent.
6. Always `pbir -q` and `--json` / `-F json`.

## 2. Mode router

| `$ARGUMENTS` / intent | Do |
|---|---|
| `plan`, new report, "build me a dashboard" (greenfield) | phases 1-11 |
| existing report change (brownfield) | section 5 routing, then phases 7-8 |
| measure / column / relationship only (model-only) | cascade + `te validate` + live DAX check; screenshot only if a visual binds it |
| `verify` | phase 8 only |
| `review`, audit, "is this report good" | `reports:review-report` + `pbir -q bpa run` + `pbi-visual-reviewer` |
| `publish` | phase 10 only (never without the gate) |
| setup / tools missing | `/powerbi-developer:setup` |

## 3. Phases (commands in `references/pipeline.md`)

| # | Phase | Who | Artefact | Gate |
|---|---|---|---|---|
| 0 | Tool health | SessionStart hook, `/powerbi-developer:setup` | banner | never block on npm tools |
| 1 | Define | this skill; AskUserQuestion, <= 5 rounds, one question each; `pbir-cli\references\vague-prompts.md` | `_brief\notes.md` | audience, job, scope, delivery known |
| 2 | Inspect model | `te list`, MCP `list_*`, `build_model_inventory.py`, `pbir model -d/-q` | `_brief\model-inventory.json` | fields verified; gaps listed; `.`-tables flagged |
| 3 | Design | `reports:pbi-report-design` + `references/design-contract.md` | `Design Brief:` YAML | acceptance checklist |
| 4 | Spec + approval | `templates\report-spec.template.md` | `_brief\report-spec.md` | user approves (section 7) |
| 5 | Compile | `uv run "$S\compile_brief_to_batch.py"` | `build.layout.json`, `build.batch.json`, `build.pages.ps1`, `build.post.ps1`, `build.run.ps1` | compiler exit 0; `build.run.ps1 -DryRun` ok |
| 6 | Build | git branch `agent/<intent>` (offer init; never auto-commit); `pbir backup`; model via cascade; `build.run.ps1` | built report | every create step resolved a target; run ok |
| 7 | Validate | `pbir -q validate "<r>" --all --json`, `pbir -q bpa run "<r>" -o json`, `powerbi-report-author validate`, `te validate` | `_verify\<ts>\validate.json` | zero real errors; warnings triaged |
| 8 | Verify render | `Invoke-VerifyLoop.ps1` -> `pbi-visual-reviewer` -> `pbi-spec-verifier` (builds) | `manifest.json`, findings | no critical, else back to 6/7 |
| 9 | Design gate | `pbi-report-design\references\quality-gate.md` on JSON + PNGs | findings | no critical |
| 10 | Publish (opt.) | `references/publish.md`; hook asks | URL | delivery target includes publish |
| 11 | Record | learnings -> project `.claude\rules\*.md`; ask before commit | rules | - |

Dispatch the `powerbi-developer` agent for phases 5-9 when the build is more than a few commands;
give it the spec path, report path, Desktop PID (or `none`) and the approval citation.

## 4. Tool cascade (full matrix: `references/tool-cascade.md`)

- Model write: `te ... --save` -> modeling MCP -> TOM via `pbi-desktop:connect-pbid` (powershell.exe 5.1) -> `pbip:tmdl`.
- Model read: `te list/get/query` -> MCP -> `pbir model -d / -q` -> TOM.
- Report write: `pbir` only. Desktop: `pbir desktop` -> `powerbi-desktop` -> raw pipe.
- Validate: `pbir validate --all` + `bpa run` -> `powerbi-report-author validate` -> `pbip:pbip-validator`.
- Publish/govern: `pbir publish` (asks) -> `fabric-cli`.
- Degrade silently: Node absent -> no MCP/npm CLIs; te expired (preview builds expire; the banner shows the date) -> MCP -> TOM -> TMDL;
  bridge absent -> validate-only (+ sandbox publish with permission); ADOMD absent -> `te query`/TOM.
  Stop if the model is Desktop-only with no te/MCP/TOM path.

## 5. Brownfield routing

| Request | Do it with | Verify | Gotcha |
|---|---|---|---|
| format a visual | `pbir visuals <sub>` / `pbir set`; theme-first via `reports:modifying-theme-json` | validate + screenshot | `pbir mv` sets the title, not the folder |
| add / move / resize visuals | `pbir add visual <type> "<r>/<Page>.Page" -n <id> -d Role:Table.Field`, `visuals position/align/distribute`; >= 3 steps -> batch spec (relative root!) | `pbir validate --qa`, screenshot | `.`-tables unbindable; check canvas size with `pbir pages json` |
| new page | `pbir add page "<r>/<Name>.Page" -n "<Name>" --width --height` | screenshot | creates the title textbox already; hide via `pbir set "...visibility" --value HiddenInViewMode` |
| theme / colours / fonts | `reports:modifying-theme-json`, `pbir theme set-*`, `pbir color/fonts` | close + reopen Desktop, screenshot | theme cache-keyed by file name |
| bookmarks / buttons / navigation | `pbir bookmarks`, `visuals action`, `pageNavigator` | screenshot of each state | bookmarks reference visuals by `name` |
| filters / slicers / interactions | `pbir add filter`, `pbir filters`, `pbir pages interactions`; patterns in `create-pbi-report\references\interactivity.md` | screenshot incl. filter pane | - |
| measure / column / relationship / RLS / calc group | cascade (section 4); `te validate`; live DAX via `te query --local` / `pbir model -q` | screenshot if bound | offline TMDL parse != DAX validation; both stores agree in the same turn |
| Power Query / M | `semantic-models:power-query` | refresh + query | `unappliedChanges.json` absent first; inline blobs: append an override step |
| rename field / table | `te move --save` -> `pbir fields replace --dry-run` -> apply -> `validate --fields` -> `pbip:pbip-validator` | validate + screenshot | field-parameter / `SWITCH` literals blank silently |
| Deneb / SVG / Python / R | `custom-visuals:*` + `reports:*-reviewer` agents | screenshot | - |
| performance | `semantic-models:dax`, `connect-pbid\references\performance-profiling.md` | Performance Analyzer JSON | traces do not stream |
| review / usage | `reports:review-report`, `pbir bpa run`, `pbir usage` | - | - |
| Copilot readiness | `semantic-for-copilot` | - | - |
| publish / endorse / labels | `references/publish.md`, `fabric-cli` | browser check | never auto-publish |

Trivial single-visual asks: 3-line minimal brief in `_brief\notes.md`, one-line confirmation, then
`pbir add visual` (design-contract.md section 6). The Stop gate still applies.

## 6. Approval gate (verbatim)

Adapted from microsoft/skills-for-fabric (MIT); see THIRD_PARTY_NOTICES.md in the repo root.
After writing `_brief\report-spec.md`, ask exactly one AskUserQuestion:
"Approve this report spec so I can start building?" with options
`Approve - start building` / `Revise audience/purpose` / `Revise scope/page plan` / `Revise design/delivery`.
Approved = locked (`APPROVED (<date>)` in the file). Later scope changes re-open the spec; they never
drift the visuals. No `pbir` mutation before approval.

## 7. Guardrails (detail: `references/gotchas.md`)

- Never hand-edit `report.json`, `mobileState.json`, `*DiagramLayout.json`, `.pbi\*` (hook denies); other
  report JSON only through pbir (hook asks). PBIP text: UTF-8 without BOM + CRLF (hook fixes and exits 2).
- `hasUnsavedChanges` before any refresh (hook denies); Desktop's own apply prompt is the safe direction.
- TOM and TMDL never disagree across a turn; TOM only under `powershell.exe` 5.1; PowerShell variables are case-insensitive.
- OneDrive: backup before `cp`/`rm`/`restore`, verify restores by hash; 260-char paths.
- Theme edits need a Desktop reopen; a dirty refresh rewrites the whole definition on disk.
- `pbir batch`: `root` relative to cwd (absolute = silent no-op); check `target_count` in the plan.
- Ask before commit, publish, `clear-formatting`, `rm`, `restore`, `te --save/deploy`, `SaveChanges` (hooks ask).

## 8. Completion criteria (the Stop hook checks the same ledger)

Every mutation validated; rendered changes screenshotted after a guarded refresh when Desktop is
available; screenshots reviewed (agent or your own Read of every PNG); builds diffed by
`pbi-spec-verifier`; findings as issue / location / severity / fix; learnings recorded; nothing
committed or published without asking; the summary says what was verified and what was not.

## 9. References

| Read when | File |
|---|---|
| running any phase | `references/pipeline.md` |
| writing or compiling a contract | `references/design-contract.md`, `templates/design-brief.example.yaml`, `templates/report-spec.template.md` |
| verifying a change | `references/verify-loop.md` |
| choosing a tool / a tool is missing | `references/tool-cascade.md` |
| something behaves oddly | `references/gotchas.md` |
| publishing or committing | `references/publish.md` |

External (read on demand). Load a whole skill by name with the Skill tool (`reports:pbir-cli`,
`reports:create-pbi-report`, `reports:pbi-report-design`, `pbi-desktop:connect-pbid`, `pbip:tmdl`,
`tabular-editor:te-cli`, `semantic-models:semantic-model`). Single reference files live under
`$DG\<plugin>\<ver>\skills\<skill>\references\` (Glob `$DG\*\*\skills\<skill>\references\<file>.md`
and take the newest `<ver>`): `pbir-cli\references\{desktop-integration,te-cli-tandem,cli-reference,bpa,vague-prompts}.md`,
`create-pbi-report\SKILL.md` (steps 6-10), `pbi-report-design\references\quality-gate.md`,
`connect-pbid\references\desktop-bridge.md`.
