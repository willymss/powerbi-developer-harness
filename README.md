# Power BI Developer Harness

A Claude Code plugin marketplace for guarded, end-to-end Power BI development on Windows. Its plugin,
`powerbi-developer`, plans a report, locks a design contract, waits for your approval, builds it with
`pbir`, validates it, reloads and screenshots it in Power BI Desktop, and has a second agent review the
pixels before it is allowed to say it is done. Hooks enforce that loop rather than merely describe it.

It is a hybrid of three sources:

- **Process** from Microsoft's Power BI agentic guidance ([microsoft/skills-for-fabric](https://github.com/microsoft/skills-for-fabric)):
  define, inspect, spec, approve, build, validate, independent screenshot review.
- **Tooling** from the [data-goblin/power-bi-agentic-development](https://github.com/data-goblin/power-bi-agentic-development)
  plugins, which it routes to rather than copies: `pbir`, `te`, `connect-pbid`, `tmdl`, `fabric-cli`.
- **Guardrails** learned the hard way on production PBIP projects: hooks that stop a canvas reload over unsaved
  work, block hand edits of undocumented report files, strip BOMs, and refuse to finish without evidence.

Full documentation: **https://willymss.github.io/powerbi-developer-harness/** (source: [`docs/index.html`](docs/index.html)).

## Install on a new machine

Requirements: Windows, [Claude Code](https://code.claude.com) 2.1.259+, PowerShell 7 (`pwsh`), git,
[uv](https://docs.astral.sh/uv/), Power BI Desktop.

```powershell
git clone https://github.com/willymss/powerbi-developer-harness.git $env:TEMP\pbidev-bootstrap
pwsh -NoProfile -File $env:TEMP\pbidev-bootstrap\scripts\bootstrap.ps1
```

or by hand:

```powershell
claude plugin marketplace add https://github.com/data-goblin/power-bi-agentic-development.git
claude plugin marketplace add https://github.com/willymss/powerbi-developer-harness.git
claude plugin install powerbi-developer@powerbi-developer-harness
```

The install pulls in the six data-goblin plugins it depends on (`reports`, `pbip`, `semantic-models`,
`pbi-desktop`, `tabular-editor`, `fabric-cli`). Then:

1. `/plugin` -> **Marketplaces** -> enable auto-update for both marketplaces (off by default for third-party ones).
2. Restart Claude Code. The `[powerbi-developer]` banner should print once.
3. In a session: `/powerbi-developer:setup -Install` to install `pbir`, `te` and the Microsoft CLIs.
4. For a Power BI working folder, copy the plugin's `harness-template/` files into it
   (`.claude/settings.json`, `CLAUDE.md`, `.gitignore`).

## Updating

`plugin.json` carries no `version`, so every pushed commit is a new version. With auto-update on, machines
pick it up at the next session start (then `/reload-plugins`). By hand:

```powershell
claude plugin marketplace update powerbi-developer-harness
claude plugin update powerbi-developer@powerbi-developer-harness
```

## Developing

Keep the clone out of OneDrive (for example `C:\dev\powerbi-developer-harness`) and point the skills-dir
loader at it with a junction, so the working tree loads live as `powerbi-developer@skills-dir`:

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\powerbi-developer" `
         -Target "C:\dev\powerbi-developer-harness\plugins\powerbi-developer"
```

On that machine do not also install `powerbi-developer@powerbi-developer-harness` (hooks would run twice),
and drop that line from a copied `harness-template/settings.json`. `SKILL.md` edits apply live; hooks,
agents and `.mcp.json` need `/reload-plugins`. Before pushing:

```powershell
pwsh -NoProfile -File scripts\validate.ps1
```

## Layout

```
.claude-plugin/marketplace.json     marketplace (allows dependencies on power-bi-agentic-development)
plugins/powerbi-developer/          the plugin: skills, agents, hooks, scripts, templates, evals, harness-template
docs/index.html                     documentation page, served by GitHub Pages (main branch, /docs)
scripts/bootstrap.ps1               new-machine setup
scripts/validate.ps1                manifest, syntax and portability checks (also run in CI)
```

## Licence

MIT, see [`LICENSE`](LICENSE). Adapted Microsoft material and credit for the data-goblin plugins are in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). The tools it drives (`pbir-cli`, Tabular Editor CLI,
Microsoft preview packages) are not bundled and carry their own terms; `pbir-cli` restricts commercial use.
