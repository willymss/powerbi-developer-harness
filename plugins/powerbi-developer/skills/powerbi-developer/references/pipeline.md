# Pipeline runbook (phases 0-11, exact commands)

Conventions: `<r>` = the report folder, always an **absolute** path (`C:\dev\pbi\Sales\Sales.Report`);
`<m>` = the `.SemanticModel` folder; `<pid>` = the Desktop PID from the banner; `_brief\` and
`_verify\<ts>\` live beside the `.pbip`. Every `pbir` call: `pbir -q ... --json` (or `-F json`).
Scripts: `$S = "${CLAUDE_PLUGIN_ROOT}\skills\powerbi-developer\scripts"` run through the PowerShell tool.

## 0. Tool health

Read the `[powerbi-developer]` banner. Missing required tool -> tell the user to run
`/powerbi-developer:setup -Install`; continue on the pbir-only path. Node tools never block.

## 1. Define (planning)

AskUserQuestion, one question per round, at most 5 rounds; never re-ask what the prompt already
answered. Order: audience + job -> scope (pages, KPIs, comparison basis) -> delivery target
(local / publish / both) -> canvas + theme -> anything blocking. Vague prompts: follow
`reports\...\pbir-cli\references\vague-prompts.md` (ask, do not guess). Write `_brief\notes.md`.

## 2. Inspect the model

```powershell
te list -m "<m>" --output-format json > _brief\te-tables.json          # 1st tier
uv run "$S\build_model_inventory.py" --model "<m>" --out _brief\model-inventory.json   # always (offline, names only)
pbir -q model "<r>" -d -F json                                           # what the report can see
pbir -q model "<r>" -q "EVALUATE TOPN(5, VALUES('dim_date'[Month]))" -F json   # sample values
```
MCP tier: `list_tables`, `list_measures`, `execute_dax`. TOM tier: `connect-pbid` scripts under
`powershell.exe`. Record gaps (missing measures) in the spec's *Model requirements*; flag every
`.`-prefixed table as unbindable through pbir.

## 3. Design

Use `reports:pbi-report-design` (tone x signature x page shape) and `references/design-contract.md`.
Output: the `Design Brief:` YAML with a per-page `layout_contract`; run the acceptance checklist in
your head before writing it down.

## 4. Spec + approval

Fill `templates\report-spec.template.md` -> `_brief\report-spec.md`. Then the approval gate
(SKILL.md section 7). No `pbir` mutation before approval. Mark the file `APPROVED (<date>)`.

## 5. Compile

```powershell
uv run "$S\compile_brief_to_batch.py" --spec _brief\report-spec.md --report "<r>" --model-inventory _brief\model-inventory.json --json
pbir -q batch validate _brief\build.batch.json --json
pbir -q batch plan _brief\build.batch.json --json > _brief\build.plan.json    # note plan_digest
```
Compiler errors = contract problems: fix the contract, never the generated files. Dot-table abort ->
report the unbindable fields and either move them out of the contract or plan a Desktop step.

## 6. Build

```powershell
git status  # offer `git init` + baseline commit when there is no repo; work on branch agent/<intent>; never auto-commit
pbir -q backup "<r>" -m "<intent>"
# model objects first (relationships before measures), through the cascade:
te add Measure "'Sales'[Revenue YoY %]" -m "<m>" --expression "<DAX>" --save   # or MCP / TOM / tmdl
te validate -m "<m>"
pwsh -NoProfile -File _brief\build.pages.ps1                              # pages, backgrounds, title boxes
pbir -q batch run _brief\build.batch.json --plan-digest <digest> --dry-run --json
pbir -q batch run _brief\build.batch.json --plan-digest <digest> --json
pwsh -NoProfile -File _brief\build.post.ps1                               # sorts, filters
```
Greenfield report: `pbir -q new report "<r>" -F pbip -c "<Workspace>/<Model>.SemanticModel"` (thin by
default; `--thick` only when the user owns the model locally; `--no-title` when the contract has its own
title placement). `pbir -q pages active-page "<r>" "<Landing>"` for the landing page. For step details
that this plugin does not restate (query reduction, navigation, slicer sync) read
`reports\...\create-pbi-report\SKILL.md` steps 6-10.

## 7. Validate

```powershell
pbir -q validate "<r>" --all --json
pbir -q bpa run "<r>" -o json
powerbi-report-author validate "<r>" --format json      # when installed; second opinion
te validate -m "<m>"                                    # after any model change
```
Zero errors required. Triage warnings: `TABLE_NOT_FOUND` on `.`-prefixed entities is a known false positive.

## 8. Verify render

```powershell
pwsh -NoProfile -File "$S\Invoke-VerifyLoop.ps1" -Report "<r>" -DesktopPid <pid> [-Pages A,B] [-Model] -Json
```
Then dispatch `pbi-visual-reviewer` (manifest path + what changed) and, for builds,
`pbi-spec-verifier` (`_brief\build.layout.json`). Details: `references/verify-loop.md`.

## 9. Design gate

Run `reports\...\pbi-report-design\references\quality-gate.md` against the JSON and the screenshots.
No critical findings.

## 10. Publish (only when the delivery target says so)

`references/publish.md`. The hook asks before `pbir publish`.

## 11. Record

New gotchas -> the project's `.claude\rules\*.md` (symptom / detection / fix). Ask before any commit.

## Brownfield short path

Route by the table in SKILL.md section 5, then phases 7-8 only. Trivial single-visual asks use the
minimal brief (design-contract.md section 6).
