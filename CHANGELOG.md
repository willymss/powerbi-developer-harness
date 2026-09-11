# Changelog

Versions are git commits (`plugin.json` has no `version` field); entries here are dated.

## 2026-09-11 - first public release

- Published as the `powerbi-developer-harness` marketplace with one plugin, `powerbi-developer`.
- Dependencies on the six data-goblin plugins declared in the marketplace entry, so one install pulls them in.
- The raw named-pipe Desktop client in `Get-PbiDesktopState.ps1` is now an independent implementation; reads use
  `ReadAsync` with a deadline because pipes do not support `ReadTimeout`.
- The data-goblin skill references resolve the newest installed version instead of a pinned path.
- Examples moved to a neutral retail model (`fact_sales`, `dim_product`, `dim_date`).
- Added `LICENSE` (MIT), `THIRD_PARTY_NOTICES.md`, `scripts/bootstrap.ps1`, `scripts/validate.ps1` and CI.

## 2026-09-04 - 0.1.0 (local only)

Built and verified on one machine against a git-baselined sandbox copy of a real report:

- `claude plugin validate --strict` passed; always-on context cost about 400-800 tokens, about 4.5k when the skill fires.
- Every hook path unit-tested with piped JSON: hand-edit ask/deny, BOM strip + exit 2, invalid JSON exit 2,
  refresh deny/ask, hazard asks, ledger kinds, the Stop gate's block sequence, the kill switch.
- Compiler on `design-brief.example.yaml`: header box `32,32,1224,56`, filter slots `1288/1600 x 288`; batch spec valid.
- Greenfield smoke: a page and three visuals created with contract ids, a sort and a page filter applied,
  `verify_spec.py` clean.
- Verify loop: validation triage (14 degraded-schema false positives, 0 real errors), unsaved-Desktop stop
  (exit 4), no-instance stop (exit 5).
- Not yet exercised: a live refresh + screenshot round trip, `claude plugin eval` (early access), the modeling
  MCP tool surface, `te` writes.
