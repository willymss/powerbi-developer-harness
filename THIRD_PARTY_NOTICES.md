# Third-party notices and credits

This repository is MIT-licensed (see `LICENSE`). It combines original work with text adapted from, and
tooling routed to, the projects below.

## microsoft/skills-for-fabric (MIT)

https://github.com/microsoft/skills-for-fabric

Adapted material:

| This repo | Source in skills-for-fabric | How |
|---|---|---|
| `plugins/powerbi-developer/skills/powerbi-developer/references/design-contract.md` | `skills/powerbi-report-design/references/design-brief.md` | Design Brief schema keys kept verbatim so their briefs compile unchanged; grid and placement rules adapted |
| `plugins/powerbi-developer/skills/powerbi-developer/templates/design-brief.example.yaml` | same | field names of the brief |
| `plugins/powerbi-developer/skills/powerbi-developer/templates/report-spec.template.md` | `skills/powerbi-report-planning/SKILL.md` | spec section order and headings, lightly adapted |
| `plugins/powerbi-developer/skills/powerbi-developer/references/verify-loop.md` | `skills/powerbi-report-authoring/references/screenshot-review.md` | review checklist, condensed |
| `plugins/powerbi-developer/skills/powerbi-developer/SKILL.md` section 6 | `skills/powerbi-report-planning/SKILL.md` | the approval question wording |

The pipeline shape (define, inspect, spec, approve, build, validate, independent screenshot review) follows
Microsoft's Power BI agentic guidance.

```
MIT License

Copyright (c) 2026 Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## data-goblin/power-bi-agentic-development (GPL-3.0), by Kurt Buhler

https://github.com/data-goblin/power-bi-agentic-development

`powerbi-developer` is built on top of these plugins and routes to them at runtime (`reports`, `pbip`,
`semantic-models`, `pbi-desktop`, `tabular-editor`, `fabric-cli`); they are installed from their own
marketplace as dependencies and none of their files are copied into this repository. Specifically:

- The skill's stance (blunt, no emojis, push back on one-shot prompts) paraphrases the `pbir-cli` skill's mental model.
- The raw named-pipe fallback in `Get-PbiDesktopState.ps1` is an independent implementation of the Desktop
  bridge protocol that the `pbi-desktop` plugin documents in `skills/connect-pbid/references/desktop-bridge.md`.
- Many of the gotchas and the tool cascade were learned while using `pbir`, `te` and `connect-pbid` as those
  plugins teach them.

## Tools this plugin drives (not bundled)

| Tool | Terms |
|---|---|
| `pbir-cli` | its own licence, which restricts commercial use; confirm the terms before relying on it for company work |
| Tabular Editor CLI (`te`) | preview software with an expiry date, under Tabular Editor's terms |
| `@microsoft/powerbi-modeling-mcp`, `@microsoft/powerbi-desktop-bridge-cli`, `@microsoft/powerbi-report-authoring-cli` | Microsoft preview packages under their own terms |
| Power BI Desktop | Microsoft product terms |
