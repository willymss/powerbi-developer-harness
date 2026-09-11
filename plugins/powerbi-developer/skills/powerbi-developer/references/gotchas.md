# Gotchas: symptom -> detection -> fix -> area

Learned on production PBIP projects (pbir 0.9.x, Power BI Desktop 2026 builds, Windows).
The hooks enforce the first block mechanically; the rest are judgement calls the skill must apply.

## Enforced by hooks

| Symptom | Detection | Fix | Area |
|---|---|---|---|
| Desktop refuses to open the whole PBIP after an edit | `Test-Utf8NoBom.ps1 -Path <project> -Recurse` (post-edit hook strips it and exits 2) | Write UTF-8 **without BOM** + CRLF: `[IO.File]::WriteAllText(p, t, [Text.UTF8Encoding]::new($false))`; never `Set-Content -Encoding UTF8` in PS 5.1 | PBIP hot apply |
| Canvas refresh wiped unsaved Desktop work / rewrote the definition | `pbir -q desktop status --json` -> `hasUnsavedChanges: true` (refresh guard denies) | Save or discard in Desktop first; the safe direction is Desktop's external-changes prompt | PBIP hot apply |
| Edited `report.json` / `mobileState.json` / `*DiagramLayout.json` / `.pbi\*` rejected by Desktop | hand-edit guard denies | Only pbir writes report JSON; those files are undocumented | PBIP hot apply |
| `pbir rm` leaves an empty visual folder, next `add visual -n` gets an auto name | hazard guard asks; `[WinError 5] Access is denied` | OneDrive marks dirs ReadOnly; `pbir backup` first, delete the empty folder, re-add | pbir |
| `pbir cp` of a visual silently breaks bookmarks | hazard guard asks | cp assigns a new `name`; bookmarks reference visuals by `name`; use `pbir set`/batch on the existing visual | pbir |
| `pbir restore` deleted visuals on an unrelated page and could not roll back | hazard guard asks | `Copy-Item -Path (Join-Path $bk '*')` from the backup + `Get-FileHash` compare (`-LiteralPath` does not expand `*`) | pbir |
| TOM `SaveChanges` and TMDL disagree; a later apply/save picks the stale one | hazard guard asks on `SaveChanges` / `te --save` | Write the same expression to disk in the same turn; compare the live expression (TOM) with the TMDL file before ending the turn | PBIP hot apply |

## Model / DAX

| Symptom | Detection | Fix | Area |
|---|---|---|---|
| `Could not load type 'System.Runtime.Remoting.Messaging.CallContext'` | running TOM under `pwsh` | TOM/ADOMD only under `powershell.exe -NoProfile -ExecutionPolicy Bypass -File` (5.1) | TOM / DAX |
| Every query fails with `Failed to resolve name 'SYNTAXERROR'` | one measure uses a reserved VAR name (`Sections`, `Row`, `Cells`, `cell`) | rename the VAR; validate bodies via `DEFINE MEASURE 'T'[__t] = <body>`; an offline TMDL parse is **not** DAX validation | TOM / DAX |
| `MPARAMETER` syntax error | bare `MPARAMETER` | `DEFINE MPARAMETER 'param' = "v"` in the **same** command text as `EVALUATE` | TOM / DAX |
| Whole report blank after editing a calculated table partition | the calculated table "does not hold any data" | `$model.RequestRefresh(Calculate)` + SaveChanges; gate on a whole-model canary, not the rows you touched | TOM / DAX |
| `[Order] contains blank values` after inserting an M row | `Table.InsertRows` with a typed literal | coerce each value to the runtime type of an existing row; text columns stay text | TOM / DAX |
| Two measures corrupted with each other's expression | PowerShell variables are **case-insensitive**: `$NEW`/`$new`, `$PANEL`/`$panel`, `$MT`/`$mt`, `$Root`/`$root` | never name a loop variable or object a case-variant of a constant/param; gate text splices on `abs(delta) <= few chars` + marker count before saving | TOM / DAX |
| DAX predicate mangled when passed as a `powershell.exe -File` argument | fragments land in other params | write the predicate to a temp file and pass the path | TOM / DAX |
| `Write-Output` in a function joins the return value | member enumeration silently works | `Write-Host` for progress inside functions whose result you consume | TOM / DAX |
| Median off by one | `[int](3/2)` = 2 (banker's rounding) | `[math]::Floor(($a.Count-1)/2)` | TOM / DAX |
| Traces never deliver events | `IsStarted` true, zero events | use a Performance Analyzer JSON export (`Execute DAX Query` / `Execute Direct Query` QueryText) | TOM / DAX |
| On-disk M partition edit vanished | `<Model>.SemanticModel\.pbi\unappliedChanges.json` exists | do not edit partitions on disk while it exists; apply pending changes in Desktop first | PBIP hot apply |
| `pbir model -q` fails on a thick report | ADOMD missing | `PBIR_ADOMD_DIR` -> connect-pbid's `$env:TEMP\tom_nuget\...\lib\net45` or DAX Studio; else `te query` / TOM | pbir |

## Report / pbir

| Symptom | Detection | Fix | Area |
|---|---|---|---|
| `pbir batch run` reports every step `ok` but nothing changed | `batch plan --json` shows `target_count: 0` on create/set steps | `root` must be RELATIVE to the working directory (`"Sales.Report"`, cwd = project folder); an absolute root silently resolves nothing. `build.run.ps1` sets the cwd and refuses to run when a create step has 0 targets | pbir 0.9.31 |
| Visual cannot render after binding `.Measures.X` | `Entity: ""` in the projection; compiler aborts | pbir splits at the first dot; bind in Desktop or rename the table (field-parameter/SWITCH literals blank silently on rename) | pbir |
| Hundreds of `TABLE_NOT_FOUND` warnings on `--fields` | all on `.`-prefixed entities | false positive; judge by the projection, not the count | pbir |
| `pbir pages hide` prints success, writes nothing | re-read shows unchanged | `pbir set "<Page>.visibility" --value HiddenInViewMode` | pbir |
| `pbir mv` on a visual overwrote its title | folder unchanged, title changed | mv sets the title; folder names are opaque, do not rename visuals | pbir |
| Two title textboxes stacked at (20,20) | `add title` after `add page` | `add page` already creates the title textbox | pbir |
| `pbir validate --json -o FILE` writes nothing | file absent | capture stdout | pbir |
| Theme edit invisible after refresh | Desktop caches themes by file name | rename the theme (`pbir theme rename`) or close + reopen Desktop | Desktop |
| Path errors on long names | > 260 chars | short project root (`$env:PBI_PROJECTS_ROOT\<name>`, default `C:\dev\pbi`), short table/visual names | PBIP hot apply |
| `pbir open "<abs>\X.Report"` launched a DIFFERENT file (`<profile base_dir>\X.pbix`) | Desktop opens a file from the active profile's folder; `pbir desktop status` shows an unexpected `.pbix` | never use `pbir open` with an active profile that points elsewhere; open with `powerbi-desktop open "<abs>\X.pbip" --timeout 180` or `Start-Process "<abs>\X.pbip"` | pbir 0.9.31 |
| `pbir` acts on the wrong report | active profile (`pbir connect`) points elsewhere | always pass explicit report paths; SessionStart banner shows the profile | pbir |
| Save failures / `Permission denied` mid-command | OneDrive sync | new projects under `$env:PBI_PROJECTS_ROOT` (default `C:\dev\pbi`); re-run and verify with `pbir get`; PBIP on OneDrive is unsupported by Microsoft | PBIP hot apply |
| Transient `not_connected` from the bridge | Desktop still loading / modal open | retry once after a few seconds; if it persists, relay the preview-feature steps once and fall back to validate-only | Desktop |
