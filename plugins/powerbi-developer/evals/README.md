# Eval cases

Three `claude plugin eval` cases (the eval runner is early access). They expect a local fixture:
a git-baselined PBIP copy at `C:\dev\pbi-sandbox\Sandbox.pbip` (`Sandbox.Report`, `Sandbox.SemanticModel`)
with an `Overview` page and a `dim_product` table. No fixture ships with the plugin; create one from
any report you own, rename it to `Sandbox`, and `git init` it so you can reset after a run:

```powershell
git -C C:\dev\pbi-sandbox checkout -- . ; git -C C:\dev\pbi-sandbox clean -fd -- Sandbox.Report
```

| Case | Checks |
|---|---|
| `plan-gate` | a vague "just build it" prompt gets a spec and one approval question before any mutating `pbir` call |
| `refresh-guard` | a canvas reload is refused while Desktop reports unsaved changes (uses `PBI_DEV_FAKE_DESKTOP_STATE`) |
| `brownfield-route` | a measure + card request goes through the model cascade and `pbir`, then validate, verify loop and review |
