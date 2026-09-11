# Publish and version control

## Publish gate

Publish only when the approved spec's delivery target includes it, `pbir validate --all` is clean,
the verify loop ran and the reviewer passed, and the user confirmed the destination in this turn.
The hazard hook asks before any `pbir publish`.

```powershell
pbir auth status                                                   # signed in?
pbir -q publish "<r>" "<Workspace>.Workspace/<Report>.Report" -f    # overwrite; -o opens the browser
pbir -q publish "<r>"                                               # back to the report's saved link
pbir -q report rebind "<r>" --connection "<Workspace>/<Model>.SemanticModel"   # thin report pointing at a workspace model
```

Governance (endorsement, sensitivity labels, access, workspace settings): hand off to the
`fabric-cli:fabric-cli` skill (`fab auth status` first). Never publish to a production workspace
from a sandbox build; prefer a sandbox workspace for browser inspection when Desktop is unavailable.

## Git policy

- No repo -> offer `git init` and a baseline commit **before** the first mutation. PBIP folders belong
  under `$env:PBI_PROJECTS_ROOT\<name>` (default `C:\dev\pbi`; short path, not OneDrive).
- Work on `agent/<intent>` (Microsoft uses `copilot/*`; the decision tree in their
  `version-control.md` applies: branch per intent, never commit generated caches).
- `.gitignore`: `**/.pbi/localSettings.json`, `**/.pbi/editorSettings.json`, `_verify/`, `screenshots/`,
  `*.pbir-restore-tmp/`, `.claude/settings.local.json`. Keep `.pbi/cache.abf` out of git too unless the
  team wants import data versioned (it is large).
- **Ask before every commit**; never `git push --force`, `git reset --hard` or `git clean -f` (denied by
  the project harness). Summarise the diff (`git diff --stat`) in the ask.
- Rollback options, in order: `git checkout -- <path>` (when a baseline exists), `pbir restore` from
  `pbir backup --list` (verify by hash; the hook asks), Copy-Item from the backup folder.
