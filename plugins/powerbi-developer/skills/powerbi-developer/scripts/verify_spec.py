"""Verify a built PBIR report against its compiled layout (build.layout.json). Read-only, stdlib only.

  uv run verify_spec.py --layout _brief/build.layout.json --report "C:\\dev\\pbi\\Sales\\Sales.Report" [--tolerance 8] [--json]

Reads the report's page.json / visual.json files directly (pbir is the writer; reading the JSON is
safe and needs no model). Matching order per placement: visual `name` == placement id, then title
text, then same visual type with the nearest box. Findings: page_missing, missing, extra,
type_mismatch, drift (position/size beyond tolerance), binding_mismatch. Each finding carries the
pbir command that fixes it. Exit 1 when any missing / page_missing / type_mismatch / binding_mismatch.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def literal(v):
    """Unwrap a PBIR literal expression like {'expr': {'Literal': {'Value': "'Text'"}}}."""
    try:
        val = v["expr"]["Literal"]["Value"]
        if isinstance(val, str) and len(val) >= 2 and val[0] == "'" and val[-1] == "'":
            return val[1:-1]
        return val
    except Exception:
        return None


def read_json(p: Path):
    return json.loads(p.read_text(encoding="utf-8-sig"))


def load_report(report_dir: Path) -> dict:
    pages_dir = report_dir / "definition" / "pages"
    out: dict[str, dict] = {}
    if not pages_dir.exists():
        return out
    for pj in pages_dir.glob("*/page.json"):
        try:
            page = read_json(pj)
        except Exception:
            continue
        visuals = []
        for vj in list(pj.parent.glob("visuals/*/visual.json")) + list(pj.parent.glob("*/visual.json")):
            try:
                v = read_json(vj)
            except Exception:
                continue
            vis = v.get("visual", {}) or {}
            pos = v.get("position", {}) or {}
            title = None
            try:
                t = (v.get("visual", {}).get("visualContainerObjects", {}) or {}).get("title", [])
                if t:
                    title = literal(t[0].get("properties", {}).get("text", {}))
            except Exception:
                pass
            bindings = []
            qs = (vis.get("query", {}) or {}).get("queryState", {}) or {}
            for role, block in qs.items():
                for proj in block.get("projections", []) or []:
                    f = proj.get("field", {}) or {}
                    node = f.get("Column") or f.get("Measure") or f.get("Aggregation", {}).get("Expression", {}).get("Column") or {}
                    ent = ((node.get("Expression", {}) or {}).get("SourceRef", {}) or {}).get("Entity")
                    prop = node.get("Property")
                    if ent is not None and prop is not None:
                        bindings.append({"role": role, "field": f"{ent}.{prop}"})
            visuals.append({"name": v.get("name"), "folder": vj.parent.name, "type": vis.get("visualType"),
                            "x": pos.get("x"), "y": pos.get("y"), "width": pos.get("width"), "height": pos.get("height"),
                            "title": title, "bindings": bindings})
        out[page.get("displayName", pj.parent.name)] = {"folder": pj.parent.name, "name": page.get("name"),
                                                        "width": page.get("width"), "height": page.get("height"), "visuals": visuals}
    return out


def dist(a: dict, b: dict) -> float:
    return abs((a.get("x") or 0) - b["x"]) + abs((a.get("y") or 0) - b["y"]) + abs((a.get("width") or 0) - b["width"]) + abs((a.get("height") or 0) - b["height"])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--layout", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--tolerance", type=float, default=8)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    layout = json.loads(Path(args.layout).read_text(encoding="utf-8-sig"))
    report_dir = Path(args.report)
    if not (report_dir / "definition").exists():
        print(f"not a PBIR report directory: {report_dir}", file=sys.stderr)
        return 2
    built = load_report(report_dir)
    rq = str(report_dir)
    findings: list[dict] = []
    counts = {"pages": 0, "placements": 0, "matched": 0}

    for pg in layout.get("pages", []):
        counts["pages"] += 1
        bp = built.get(pg["name"])
        page_path = f'{rq}/{pg["name"]}.Page'
        if not bp:
            findings.append({"issue": "page_missing", "location": pg["name"], "severity": "critical",
                             "fix": f'pbir -q add page "{page_path}" -n "{pg["name"]}" --width {pg["canvas"]["width"]} --height {pg["canvas"]["height"]}'})
            continue
        if bp.get("width") != pg["canvas"]["width"] or bp.get("height") != pg["canvas"]["height"]:
            findings.append({"issue": "drift", "location": f'{pg["name"]} (page size {bp.get("width")}x{bp.get("height")})', "severity": "warning",
                             "fix": f'pbir -q pages resize "{page_path}" --width {pg["canvas"]["width"]} --height {pg["canvas"]["height"]}'})
        unmatched = list(bp["visuals"])
        for pl in pg["placements"]:
            counts["placements"] += 1
            vpath = f'{page_path}/{pl["id"]}.Visual'
            cand = next((v for v in unmatched if v.get("name") == pl["id"]), None)
            if cand is None and pl.get("title"):
                cand = next((v for v in unmatched if v.get("title") == pl["title"]), None)
            if cand is None and pl["visual_type"] == "textbox":
                cand = next((v for v in unmatched if v.get("type") == "textbox"), None)
            if cand is None:
                same = [v for v in unmatched if v.get("type") == pl["visual_type"]]
                if same:
                    cand = min(same, key=lambda v: dist(v, pl))
                    if dist(cand, pl) > 4 * args.tolerance + 200:
                        cand = None
            if cand is None:
                b = " ".join(f'-d "{x["role"]}:{x["field"]}"' for x in pl.get("bindings", []))
                findings.append({"issue": "missing", "location": f'{pg["name"]}/{pl["id"]}', "severity": "critical",
                                 "fix": f'pbir -q add visual {pl["visual_type"]} "{page_path}" -n "{pl["id"]}" -x {pl["x"]} -y {pl["y"]} -w {pl["width"]} -h {pl["height"]} {b}'.strip()})
                continue
            unmatched.remove(cand)
            counts["matched"] += 1
            actual_path = f'{page_path}/{cand.get("name") or cand.get("folder")}.Visual'
            if cand.get("type") != pl["visual_type"]:
                findings.append({"issue": "type_mismatch", "location": f'{pg["name"]}/{pl["id"]} (built {cand.get("type")}, expected {pl["visual_type"]})', "severity": "critical",
                                 "fix": f'pbir -q rm "{actual_path}" -f  # then re-add as {pl["visual_type"]} (no in-place type change)'})
                continue
            if dist(cand, pl) > args.tolerance:
                findings.append({"issue": "drift", "location": f'{pg["name"]}/{pl["id"]} at ({cand.get("x")},{cand.get("y")}) {cand.get("width")}x{cand.get("height")}; expected ({pl["x"]},{pl["y"]}) {pl["width"]}x{pl["height"]}', "severity": "warning",
                                 "fix": f'pbir -q visuals position "{actual_path}" --x {pl["x"]} --y {pl["y"]} --width {pl["width"]} --height {pl["height"]}'})
            want = {(b["role"].lower(), b["field"].lower()) for b in pl.get("bindings", [])}
            have = {(b["role"].lower(), b["field"].lower()) for b in cand.get("bindings", [])}
            if want and want != have:
                missing = sorted(want - have)
                extra = sorted(have - want)
                fix = " ".join([f'pbir -q visuals bind "{actual_path}"'] + [f'-a "{r}:{f}"' for r, f in missing] + [f'-r "{r}:{f}"' for r, f in extra])
                findings.append({"issue": "binding_mismatch", "location": f'{pg["name"]}/{pl["id"]} missing={missing} extra={extra}', "severity": "critical", "fix": fix})
        for v in unmatched:
            findings.append({"issue": "extra", "location": f'{pg["name"]}/{v.get("name") or v.get("folder")} ({v.get("type")})', "severity": "suggestion",
                             "fix": f'pbir -q rm "{page_path}/{v.get("name") or v.get("folder")}.Visual" -f  # only if it is not intentional'})
    critical = [f for f in findings if f["severity"] == "critical"]
    result = {"ok": not critical, "counts": counts, "findings": findings,
              "by_issue": {k: sum(1 for f in findings if f["issue"] == k) for k in ("page_missing", "missing", "extra", "type_mismatch", "drift", "binding_mismatch")}}
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"pages {counts['pages']}, placements {counts['placements']}, matched {counts['matched']}, findings {len(findings)} ({len(critical)} critical)")
        for f in findings:
            print(f"- [{f['severity']}] {f['issue']}: {f['location']}\n    fix: {f['fix']}")
    return 1 if critical else 0


if __name__ == "__main__":
    sys.exit(main())
