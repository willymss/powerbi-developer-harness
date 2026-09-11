# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6"]
# ///
"""Compile a `Design Brief:` contract into pbir build artefacts.

Usage (run with uv so pyyaml resolves):
  uv run compile_brief_to_batch.py --spec _brief/report-spec.md --report "C:\\dev\\pbi\\Sales\\Sales.Report" \
      [--out-dir _brief] [--model-inventory _brief/model-inventory.json] [--pages-mode create|existing] \
      [--emit-asserts] [--strict] [--json] [--no-schema-check]

Outputs (in --out-dir):
  build.layout.json   resolved pixel boxes, types, bindings (the verifier's input)
  build.pages.ps1     page creation/resize, background, title placement, filters, sort (pbir CLI; deterministic ids)
  build.batch.json    pbir batch v2 spec: backup -> create_visual per placement -> validate_report [-> assert]
  build.report.md     human summary: checks, warnings, per-page table

Exit codes: 0 ok, 1 contract errors (listed), 2 usage / io error.
See references/design-contract.md for the rules implemented here.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("pyyaml missing: run with `uv run compile_brief_to_batch.py ...`", file=sys.stderr)
    sys.exit(2)

# ---------------------------------------------------------------- kind table (references/design-contract.md section 4)
KIND_MAP: dict[str, tuple[str, list[str]]] = {
    "title": ("textbox", []), "textbox": ("textbox", []), "text": ("textbox", []),
    "card": ("cardVisual", ["Data"]), "card_classic": ("card", ["Values"]),
    "kpi": ("kpi", ["Indicator", "TrendLine", "Goal"]), "multirow_card": ("multiRowCard", ["Values"]),
    "slicer": ("slicer", ["Values"]), "list_slicer": ("listSlicer", ["Values"]),
    "advanced_slicer": ("advancedSlicerVisual", ["Values"]),
    "table": ("tableEx", ["Values"]), "matrix": ("pivotTable", ["Rows", "Columns", "Values"]),
    "bar": ("barChart", ["Category", "Y", "Series"]), "clustered_bar": ("clusteredBarChart", ["Category", "Y", "Series"]),
    "column": ("columnChart", ["Category", "Y", "Series"]), "clustered_column": ("clusteredColumnChart", ["Category", "Y", "Series"]),
    "line": ("lineChart", ["Category", "Y", "Y2"]), "area": ("areaChart", ["Category", "Y"]),
    "combo": ("lineClusteredColumnComboChart", ["Category", "Y", "Y2"]),
    "donut": ("donutChart", ["Category", "Y"]), "pie": ("pieChart", ["Category", "Y"]),
    "scatter": ("scatterChart", ["X", "Y", "Category", "Size"]), "waterfall": ("waterfallChart", ["Category", "Y", "Breakdown"]),
    "funnel": ("funnel", ["Category", "Y"]), "treemap": ("treemap", ["Group", "Values"]),
    "gauge": ("gauge", ["Y", "TargetValue", "MinValue", "MaxValue"]), "ribbon": ("ribbonChart", ["Category", "Y", "Series"]),
    "map": ("azureMap", ["Category", "Size"]), "filled_map": ("filledMap", ["Category"]),
    "decomposition_tree": ("decompositionTreeVisual", ["Analyze", "ExplainBy"]),
    "image": ("image", []), "shape": ("shape", []), "button": ("actionButton", []),
}
TYPE_ROLES: dict[str, list[str]] = {t: roles for _, (t, roles) in KIND_MAP.items()}
TYPE_ROLES.update({
    "hundredPercentStackedBarChart": ["Category", "Y", "Series"], "hundredPercentStackedColumnChart": ["Category", "Y", "Series"],
    "hundredPercentStackedAreaChart": ["Category", "Y", "Series"], "stackedAreaChart": ["Category", "Y", "Series"],
    "lineStackedColumnComboChart": ["Category", "Y", "Y2"], "shapeMap": ["Category", "Value"], "map": ["Category", "Size"],
    "textSlicer": ["Values"], "keyDriversVisual": ["ExplainBy", "Target"],
})
SINGLE_ROLE_ALL = {"tableEx", "slicer", "listSlicer", "advancedSlicerVisual", "multiRowCard", "card", "textSlicer"}
NON_DATA_TYPES = {"textbox", "image", "shape", "actionButton", "bookmarkNavigator", "pageNavigator"}
SLICER_TYPES = {"slicer", "listSlicer", "advancedSlicerVisual", "textSlicer"}
SLICER_REGIONS = {"filters", "rail", "slicer_rail", "header", "filter_rail", "slicers"}
CARD_TYPES = {"cardVisual", "card", "kpi", "multiRowCard"}
SLICER_PRESETS = {
    "dropdown": {"data.mode": "Dropdown"},
    "list": {"data.mode": "Basic"},
    "tile": {"data.mode": "Basic", "general.orientation": "Horizontal"},
    "between": {"data.mode": "Between"},
}
EXEMPT_PREFIXES = ("bg_", "spacer_", "divider_")


class ContractError(Exception):
    pass


# ---------------------------------------------------------------- loading
def load_brief(spec_path: Path) -> dict:
    text = spec_path.read_text(encoding="utf-8-sig")
    suffix = spec_path.suffix.lower()
    if suffix == ".json":
        data = json.loads(text)
    elif suffix in (".yaml", ".yml"):
        data = yaml.safe_load(text)
    else:  # markdown: first fenced yaml block starting with 'Design Brief:'
        blocks = re.findall(r"```(?:yaml|yml)?\s*\n(.*?)```", text, flags=re.S)
        block = next((b for b in blocks if b.lstrip().startswith("Design Brief:")), None)
        if block is None:
            raise ContractError("no fenced yaml block starting with 'Design Brief:' found in " + str(spec_path))
        data = yaml.safe_load(block)
    if isinstance(data, dict) and "Design Brief" in data:
        data = data["Design Brief"]
    if not isinstance(data, dict):
        raise ContractError("contract root must be a mapping")
    return data


def load_inventory(path: Path | None) -> dict[str, dict[str, set[str]]] | None:
    """Returns {table_lower: {'columns': {names_lower}, 'measures': {names_lower}}} or None."""
    if not path:
        return None
    raw = json.loads(path.read_text(encoding="utf-8-sig"))
    inv: dict[str, dict[str, set[str]]] = {}

    def bucket(t: str) -> dict[str, set[str]]:
        return inv.setdefault(t.lower(), {"columns": set(), "measures": set()})

    if isinstance(raw, dict) and "tables" in raw:
        for t in raw["tables"]:
            b = bucket(t.get("name", ""))
            for c in t.get("columns", []):
                b["columns"].add((c if isinstance(c, str) else c.get("name", "")).lower())
            for m in t.get("measures", []):
                b["measures"].add((m if isinstance(m, str) else m.get("name", "")).lower())
    elif isinstance(raw, dict) and "fields" in raw:
        for f in raw["fields"]:
            b = bucket(f.get("table", ""))
            key = "measures" if str(f.get("type", "")).lower().startswith("m") else "columns"
            b[key].add(str(f.get("name", "")).lower())
    else:
        raise ContractError("model inventory must be {tables:[{name,columns[],measures[]}]} or {fields:[{table,name,type}]}")
    return inv


# ---------------------------------------------------------------- geometry
def snap_round(v: float, snap: int) -> int:
    return int(round(v / snap) * snap) if snap else int(round(v))


def snap_floor(v: float, snap: int) -> int:
    return int(math.floor(v / snap + 1e-9) * snap) if snap else int(math.floor(v))


def region_box(canvas: dict, grid: dict, coords: list[int]) -> tuple[float, float, float, float]:
    c1, r1, c2, r2 = coords
    W, H = canvas["width"], canvas["height"]
    m, g = canvas["margin"], canvas["gutter"]
    cols, rows = grid["columns"], grid["rows"]
    cell_w = (W - 2 * m - (cols - 1) * g) / cols
    cell_h = (H - 2 * m - (rows - 1) * g) / rows
    x1 = m + (c1 - 1) * (cell_w + g)
    x2 = m + (c2 - 1) * (cell_w + g) - g
    y1 = m + (r1 - 1) * (cell_h + g)
    y2 = m + (r2 - 1) * (cell_h + g) - g
    return x1, y1, x2, y2


def slot_box(box: tuple[float, float, float, float], slot: int, of: int, gutter: int) -> tuple[float, float, float, float]:
    x1, y1, x2, y2 = box
    w, h = x2 - x1, y2 - y1
    if w >= h:
        part = (w - (of - 1) * gutter) / of
        sx1 = x1 + (slot - 1) * (part + gutter)
        return sx1, y1, sx1 + part, y2
    part = (h - (of - 1) * gutter) / of
    sy1 = y1 + (slot - 1) * (part + gutter)
    return x1, sy1, x2, sy1 + part


def to_pixels(box: tuple[float, float, float, float], snap: int) -> dict[str, int]:
    x1, y1, x2, y2 = box
    return {"x": snap_round(x1, snap), "y": snap_round(y1, snap), "width": snap_floor(x2 - x1, snap), "height": snap_floor(y2 - y1, snap)}


# ---------------------------------------------------------------- bindings
FIELD_RX = re.compile(r"^\s*'?(?P<table>[^'\[\]]+?)'?\s*\[(?P<field>[^\]]+)\]\s*$")


def parse_field(ref: str) -> tuple[str, str]:
    m = FIELD_RX.match(ref)
    if m:
        return m.group("table").strip(), m.group("field").strip()
    if "." in ref:
        t, f = ref.split(".", 1)
        return t.strip().strip("'"), f.strip()
    raise ContractError(f"field reference '{ref}' must be Table[Field]")


def normalise_bindings(placement: dict, vtype: str, roles: list[str]) -> list[dict]:
    fb = placement.get("field_bindings")
    if fb is None:
        return []
    out: list[tuple[str, str]] = []
    if isinstance(fb, str):
        if not roles:
            raise ContractError(f"placement '{placement.get('id')}' ({vtype}) takes no data bindings")
        out.append((roles[0], fb))
    elif isinstance(fb, list):
        if not roles:
            raise ContractError(f"placement '{placement.get('id')}' ({vtype}) takes no data bindings")
        if vtype in SINGLE_ROLE_ALL or len(roles) == 1:
            out.extend((roles[0], f) for f in fb)
        else:
            for i, f in enumerate(fb):
                out.append((roles[min(i, len(roles) - 1)], f))
    elif isinstance(fb, dict):
        for role, val in fb.items():
            vals = val if isinstance(val, list) else [val]
            out.extend((str(role), v) for v in vals)
    else:
        raise ContractError(f"placement '{placement.get('id')}': field_bindings must be a string, list or mapping")
    result = []
    for role, ref in out:
        table, field = parse_field(str(ref))
        result.append({"role": role, "table": table, "field_name": field, "field": f"{table}.{field}"})
    return result


# ---------------------------------------------------------------- schema check (optional, cached)
class SchemaCheck:
    def __init__(self, enabled: bool):
        self.enabled = enabled
        self.cache: dict[str, set[str] | None] = {}

    def objects(self, vtype: str) -> set[str] | None:
        if not self.enabled:
            return None
        if vtype in self.cache:
            return self.cache[vtype]
        try:
            r = subprocess.run(["pbir", "-q", "schema", "describe", vtype, "--json"], capture_output=True, text=True, timeout=30)
            data = json.loads(r.stdout) if r.stdout.strip().startswith(("{", "[")) else None
            names: set[str] = set()
            if isinstance(data, dict):
                for key in ("objects", "containers", "properties"):
                    v = data.get(key)
                    if isinstance(v, dict):
                        names.update(v.keys())
                    elif isinstance(v, list):
                        names.update(str(o.get("name", o)) if isinstance(o, dict) else str(o) for o in v)
            self.cache[vtype] = names or None
        except Exception:
            self.cache[vtype] = None
        return self.cache[vtype]

    def supports(self, vtype: str, prop: str) -> bool:
        objs = self.objects(vtype)
        if objs is None:
            return True  # unknown -> let pbir validate at run time
        return prop.split(".", 1)[0] in objs


# ---------------------------------------------------------------- compile
def compile_contract(brief: dict, report: str, inventory, pages_mode: str, emit_asserts: bool, schema: SchemaCheck):
    errors: list[str] = []
    warnings: list[str] = []
    dot_tables: set[str] = set()

    for k in ("generated_by", "contract_version"):
        if k not in brief:
            errors.append(f"missing top-level '{k}'")
    pages = brief.get("pages")
    if not isinstance(pages, list) or not pages:
        errors.append("'pages' must be a non-empty list")
        pages = []
    color_map = {c.get("role"): c.get("hex") for c in brief.get("color_map", []) if isinstance(c, dict)}

    layout_pages = []
    pages_cmds: list[str] = []
    steps: list[dict] = [{"id": "backup", "op": "backup", "select": "."}]
    seen_page_names: set[str] = set()

    for pi, page in enumerate(pages, 1):
        name = str(page.get("name", "")).strip()
        if not name:
            errors.append(f"page #{pi}: missing name")
            continue
        if name in seen_page_names:
            errors.append(f"page '{name}': duplicate page name")
        seen_page_names.add(name)
        lc = page.get("layout_contract") or {}
        canvas = lc.get("canvas") or {}
        grid = lc.get("grid") or {}
        placements = lc.get("placements") or []
        audit = lc.get("space_audit")
        pp = page.get("pbir_page") or {}
        for k in ("width", "height", "margin", "gutter", "snap"):
            if k not in canvas:
                errors.append(f"page '{name}': layout_contract.canvas.{k} missing")
        if not all(k in grid for k in ("columns", "rows", "regions")):
            errors.append(f"page '{name}': layout_contract.grid needs columns, rows, regions")
        if not isinstance(placements, list) or not placements:
            errors.append(f"page '{name}': layout_contract.placements must be a non-empty list")
        if pp.get("width") and canvas.get("width") and pp["width"] != canvas["width"]:
            errors.append(f"page '{name}': pbir_page.width != canvas.width")
        if pp.get("height") and canvas.get("height") and pp["height"] != canvas["height"]:
            errors.append(f"page '{name}': pbir_page.height != canvas.height")
        if not isinstance(audit, dict):
            warnings.append(f"page '{name}': space_audit missing")
        else:
            if audit.get("unplaced_regions"):
                warnings.append(f"page '{name}': space_audit.unplaced_regions is not empty: {audit['unplaced_regions']}")
            limit = 20 if str(page.get("role", "")).lower().startswith("analy") else 15
            if isinstance(audit.get("empty_cell_pct"), (int, float)) and audit["empty_cell_pct"] > limit:
                warnings.append(f"page '{name}': empty_cell_pct {audit['empty_cell_pct']} > {limit}")
        if errors and any(e.startswith(f"page '{name}'") for e in errors):
            continue

        cols, rows = int(grid["columns"]), int(grid["rows"])
        regions: dict[str, list[int]] = {}
        for rname, coords in (grid.get("regions") or {}).items():
            if not (isinstance(coords, list) and len(coords) == 4 and all(isinstance(c, int) for c in coords)):
                errors.append(f"page '{name}': region '{rname}' must be [c1, r1, c2, r2] integers")
                continue
            c1, r1, c2, r2 = coords
            if not (1 <= c1 < c2 <= cols + 1 and 1 <= r1 < r2 <= rows + 1):
                errors.append(f"page '{name}': region '{rname}' {coords} out of range for {cols}x{rows} (end-exclusive)")
                continue
            regions[str(rname)] = coords

        width, height = int(canvas["width"]), int(canvas["height"])
        margin, gutter, snap = int(canvas["margin"]), int(canvas["gutter"]), int(canvas["snap"])
        page_layout = {"name": name, "canvas": {"width": width, "height": height, "margin": margin, "gutter": gutter, "snap": snap},
                       "display_option": pp.get("display_option", "FitToPage"), "background": page.get("page_background"), "placements": []}
        ids: set[str] = set()
        slicer_regions_used: set[str] = set()
        data_regions_used: dict[str, str] = {}
        title_count = 0
        data_types: list[str] = []

        for pl in placements:
            pid = str(pl.get("id", "")).strip()
            if not pid:
                errors.append(f"page '{name}': placement without id")
                continue
            if pid in ids:
                errors.append(f"page '{name}': duplicate placement id '{pid}'")
            ids.add(pid)
            region = str(pl.get("region", ""))
            if region not in regions:
                errors.append(f"page '{name}' placement '{pid}': unknown region '{region}'")
                continue
            kind = str(pl.get("kind", "")).strip()
            if kind in KIND_MAP:
                vtype, roles = KIND_MAP[kind]
            elif kind in TYPE_ROLES:
                vtype, roles = kind, TYPE_ROLES[kind]
            else:
                errors.append(f"page '{name}' placement '{pid}': unknown kind '{kind}'")
                continue
            if pl.get("pbir_visual_type"):
                vtype = str(pl["pbir_visual_type"])
                roles = TYPE_ROLES.get(vtype, roles)
            box = region_box(canvas, grid, regions[region])
            slot, of = pl.get("slot"), pl.get("of")
            if slot is not None or of is not None:
                if not (isinstance(slot, int) and isinstance(of, int) and 1 <= slot <= of):
                    errors.append(f"page '{name}' placement '{pid}': slot/of must satisfy 1 <= slot <= of")
                    continue
                box = slot_box(box, slot, of, gutter)
            px = to_pixels(box, snap)
            if px["width"] <= 0 or px["height"] <= 0:
                errors.append(f"page '{name}' placement '{pid}': zero-size box (region too small for slot/of)")
                continue
            if px["x"] < margin - snap or px["y"] < margin - snap or px["x"] + px["width"] > width - margin + snap or px["y"] + px["height"] > height - margin + snap:
                errors.append(f"page '{name}' placement '{pid}': box {px} exceeds the margins")
            try:
                bindings = normalise_bindings(pl, vtype, roles)
            except ContractError as ex:
                errors.append(f"page '{name}': {ex}")
                continue
            for b in bindings:
                if b["table"].startswith("."):
                    dot_tables.add(b["table"])
                if inventory is not None:
                    t = inventory.get(b["table"].lower())
                    fl = b["field_name"].lower()
                    if t is None:
                        warnings.append(f"page '{name}' placement '{pid}': table '{b['table']}' not in model inventory")
                    elif fl in t["measures"]:
                        b["field_type"] = "Measure"
                    elif fl in t["columns"]:
                        b["field_type"] = "Column"
                    else:
                        warnings.append(f"page '{name}' placement '{pid}': field '{b['table']}[{b['field_name']}]' not in model inventory")
            if vtype not in NON_DATA_TYPES and not bindings and vtype not in ("bookmarkNavigator", "pageNavigator"):
                warnings.append(f"page '{name}' placement '{pid}': data visual '{vtype}' has no field_bindings")
            text = pl.get("text")
            title = pl.get("title")
            if vtype == "textbox":
                title_count += 1
            for s in (text, title):
                if isinstance(s, str) and ("..." in s or "\u2026" in s):
                    warnings.append(f"page '{name}' placement '{pid}': ellipsis in text/title")
            if vtype in SLICER_TYPES:
                slicer_regions_used.add(region)
                if region not in SLICER_REGIONS:
                    warnings.append(f"page '{name}' placement '{pid}': slicer outside a slicer region ({region})")
            elif vtype not in NON_DATA_TYPES:
                data_regions_used[pid] = region
                data_types.append(vtype)
            # format
            fmt: dict = {}
            if vtype in SLICER_TYPES and pl.get("slicer_type"):
                fmt.update(SLICER_PRESETS.get(str(pl["slicer_type"]).lower(), {}))
            if title and vtype not in ("textbox",):
                fmt["title.show"] = True
                fmt["title.text"] = title
            cs = pl.get("color_strategy")
            if cs in ("primary", "neutral", "good", "bad", "accent") and color_map.get(cs) and vtype not in NON_DATA_TYPES and vtype not in SLICER_TYPES:
                prop = "dataPoint.fill" if vtype not in CARD_TYPES else None
                if prop and schema.supports(vtype, prop):
                    fmt[prop] = color_map[cs]
            for k, v in (pl.get("pbir_format") or {}).items():
                fmt[str(k)] = v
            sort = pl.get("sort_policy")
            sort_cmd = None
            if isinstance(sort, dict) and sort.get("field"):
                st, sf = parse_field(str(sort["field"]))
                if st.startswith("."):
                    dot_tables.add(st)
                sort_cmd = {"field": f"{st}.{sf}", "direction": sort.get("direction", "Ascending")}
            page_layout["placements"].append({
                "id": pid, "region": region, "kind": kind, "visual_type": vtype, **px,
                "text": text, "title": title, "bindings": bindings, "format": fmt, "sort": sort_cmd,
                "purpose": pl.get("purpose"), "insight_basis": pl.get("insight_basis"), "color_strategy": cs,
            })

        for pid, region in data_regions_used.items():
            if region in slicer_regions_used:
                warnings.append(f"page '{name}' placement '{pid}': data visual shares region '{region}' with a slicer")
        if title_count == 0:
            warnings.append(f"page '{name}': no title placement")
        if data_types and all(t in CARD_TYPES for t in data_types):
            warnings.append(f"page '{name}': bare-card hero (only cards on the page)")
        # overlaps
        pls = page_layout["placements"]
        tol = max(0, gutter - snap)
        for i in range(len(pls)):
            for j in range(i + 1, len(pls)):
                a, b = pls[i], pls[j]
                if a["id"].startswith(EXEMPT_PREFIXES) or b["id"].startswith(EXEMPT_PREFIXES):
                    continue
                ox = min(a["x"] + a["width"], b["x"] + b["width"]) - max(a["x"], b["x"])
                oy = min(a["y"] + a["height"], b["y"] + b["height"]) - max(a["y"], b["y"])
                if ox > tol and oy > tol:
                    errors.append(f"page '{name}': placements '{a['id']}' and '{b['id']}' overlap by {ox}x{oy}px")
        layout_pages.append(page_layout)

    if dot_tables:
        errors.append("tables whose name starts with '.' cannot be bound by pbir (it splits at the first dot): "
                      + ", ".join(sorted(dot_tables)) + " - bind these in Desktop or rename the table (see gotchas.md)")

    if errors:
        return None, errors, warnings

    # ---------------- emit
    rq = report.replace('"', '""')
    pages_cmds.append("# generated by compile_brief_to_batch.py - page setup, title placement, filters, sorts")
    pages_cmds.append("$ErrorActionPreference = 'Stop'")
    pages_cmds.append(f'$r = "{rq}"')
    pages_cmds.append("function Run { param([string[]]$a) Write-Host ('pbir ' + ($a -join ' ')); & pbir -q @a; if ($LASTEXITCODE -ne 0) { throw \"pbir failed: $($a -join ' ')\" } }")
    for pg in layout_pages:
        pname = pg["name"].replace('"', '""')
        page_path = f'$r/{pname}.Page'
        if pages_mode == "create":
            pages_cmds.append(f'Run @("add", "page", "{page_path}", "-n", "{pname}", "--width", "{pg["canvas"]["width"]}", "--height", "{pg["canvas"]["height"]}", "--display-option", "{pg["display_option"]}")')
        else:
            pages_cmds.append(f'Run @("pages", "resize", "{page_path}", "--width", "{pg["canvas"]["width"]}", "--height", "{pg["canvas"]["height"]}")')
        if pg.get("background"):
            pages_cmds.append(f'Run @("pages", "background", "{page_path}", "--color", "{pg["background"]}")')
        for pl in pg["placements"]:
            if pl["visual_type"] == "textbox":
                # pbir add page already creates a title textbox; move it into the title box, else create one
                pages_cmds.append(f'$tb = (& pbir -q find "{page_path}/*.Visual" --json | ConvertFrom-Json).matches | Where-Object {{ $_.visualType -eq "textbox" }} | Select-Object -First 1')
                pages_cmds.append(f'if ($tb) {{ Run @("visuals", "position", $tb.path, "--x", "{pl["x"]}", "--y", "{pl["y"]}", "--width", "{pl["width"]}", "--height", "{pl["height"]}", "--force") }}')
                pages_cmds.append(f'else {{ Run @("add", "visual", "textbox", "{page_path}", "-n", "{pl["id"]}", "--title", "{(pl.get("text") or pg["name"]).replace(chr(34), chr(34)*2)}", "-x", "{pl["x"]}", "-y", "{pl["y"]}", "-w", "{pl["width"]}", "-h", "{pl["height"]}") }}')
    # post-batch script: sorts (visuals must exist) and filters
    post_cmds = ["# generated by compile_brief_to_batch.py - run AFTER `pbir batch run`: sorts and filters",
                 "$ErrorActionPreference = 'Stop'", f'$r = "{rq}"',
                 "function Run { param([string[]]$a) Write-Host ('pbir ' + ($a -join ' ')); & pbir -q @a; if ($LASTEXITCODE -ne 0) { throw \"pbir failed: $($a -join ' ')\" } }"]
    for pg in layout_pages:
        pname = pg["name"].replace('"', '""')
        for pl in pg["placements"]:
            if pl.get("sort"):
                post_cmds.append(f'Run @("visuals", "sort", "$r/{pname}.Page/{pl["id"]}.Visual", "--field", "{pl["sort"]["field"]}", "--direction", "{pl["sort"]["direction"]}")')
    for f in brief.get("filters") or []:
        if not isinstance(f, dict) or not f.get("table") or not f.get("field"):
            warnings.append("filters[]: entries need table and field")
            continue
        scope = str(f.get("scope", "report")).lower()
        target = ["-r", "$r"] if scope == "report" else ["-p", f'$r/{str(f.get("page", "")).replace(chr(34), chr(34)*2)}.Page']
        args = ["add", "filter", str(f["table"]), str(f["field"])] + target + ["--type", str(f.get("type", "Categorical"))]
        for v in f.get("values") or []:
            args += ["--values", str(v)]
        post_cmds.append("Run @(" + ", ".join('"' + a.replace('"', '""') + '"' for a in args) + ")")
    if len(post_cmds) == 4:
        post_cmds.append("Write-Host 'nothing to do (no sorts or filters in the contract)'")

    # batch spec
    sid = 0
    for pg in layout_pages:
        for pl in pg["placements"]:
            if pl["visual_type"] == "textbox":
                continue
            sid += 1
            step = {"id": f"create_{pl['id']}"[:60], "op": "create_visual", "select": f"{pg['name']}.Page",
                    "visual_type": pl["visual_type"], "name": pl["id"], "x": pl["x"], "y": pl["y"], "width": pl["width"], "height": pl["height"]}
            if pl.get("title"):
                step["title"] = pl["title"]
            if pl["bindings"]:
                step["bindings"] = [{k: v for k, v in (("field", b["field"]), ("role", b["role"]), ("field_type", b.get("field_type"))) if v} for b in pl["bindings"]]
            if pl["format"]:
                step["format"] = pl["format"]
            steps.append(step)
    theme = brief.get("theme") or {}
    if theme.get("pbir_template"):
        steps.append({"id": "theme_apply", "op": "theme_apply", "select": ".", "source": str(theme["pbir_template"])})
    if theme.get("data_colors"):
        steps.append({"id": "theme_colors", "op": "theme_set_colors", "select": ".", "data_colors": list(theme["data_colors"])})
    steps.append({"id": "validate", "op": "validate_report", "select": ".", "structure": True, "schema": True, "qa": True})
    if emit_asserts:
        for pg in layout_pages:
            n = len([p for p in pg["placements"] if p["visual_type"] != "textbox"])
            steps.append({"id": f"assert_{re.sub(r'[^A-Za-z0-9]+', '_', pg['name'])}"[:60], "op": "assert", "select": f"{pg['name']}.Page/*.Visual",
                          "assert": {"left": "$count", "op": "gte", "right": n}, "message": f"expected at least {n} visuals on {pg['name']}"})
    # pbir batch resolves `root` ONLY as a path relative to the working directory; an absolute root
    # silently matches zero targets while every step still reports "ok". So: relative root + cwd = project dir.
    report_path = Path(report)
    project_dir = str(report_path.parent)
    report_leaf = report_path.name
    batch = {"version": 2, "name": "build-from-contract", "root": report_leaf, "stop_on_error": True,
             "defaults": {"require_plan_hash": True}, "steps": steps}
    layout = {"report": report, "project_dir": project_dir, "generated_at": datetime.now(timezone.utc).isoformat(), "contract_version": brief.get("contract_version"),
              "generated_by": brief.get("generated_by"), "mode": brief.get("mode"), "color_map": brief.get("color_map"), "pages": layout_pages}
    creators = [s["id"] for s in steps if s["op"] in ("create_visual",)]
    pdq = project_dir.replace('"', '""')
    run_cmds = [
        "# generated by compile_brief_to_batch.py - the whole build in order. -DryRun stops after the batch dry run.",
        "param([switch]$DryRun, [switch]$SkipPages)",
        "$ErrorActionPreference = 'Stop'",
        f'Set-Location -LiteralPath "{pdq}"    # pbir batch needs a RELATIVE root: cwd must be the project dir',
        f'$r = "{rq}"',
        "$brief = Split-Path -Parent $MyInvocation.MyCommand.Path",
        "function Step($n) { Write-Host \"`n== $n\" -ForegroundColor Cyan }",
        "Step 'batch validate'; $v = & pbir -q batch validate (Join-Path $brief 'build.batch.json') --json | ConvertFrom-Json; if (-not $v.ok) { throw 'batch spec invalid' }",
        "if (-not $SkipPages) { Step 'pages'; & pwsh -NoProfile -File (Join-Path $brief 'build.pages.ps1'); if ($LASTEXITCODE -ne 0) { throw 'build.pages.ps1 failed' } }",
        "Step 'plan'; $planJson = & pbir -q batch plan (Join-Path $brief 'build.batch.json') --json; $plan = $planJson | ConvertFrom-Json; if (-not $plan.ok) { throw 'batch plan failed' }",
        "[IO.File]::WriteAllText((Join-Path $brief 'build.plan.json'), ($planJson -join \"`n\"), [Text.UTF8Encoding]::new($false))",
        "$digest = $plan.plan_digest; Write-Host \"plan digest $digest\"",
        "$mustHit = @(" + ", ".join(f"'{c}'" for c in creators) + ")",
        "foreach ($s in $plan.steps) { if ($mustHit -contains $s.id -and [int]$s.target_count -lt 1) { throw \"step $($s.id) resolved 0 targets - the page does not exist or the root/cwd is wrong (batch needs a relative root)\" } }",
        "Step 'batch run --dry-run'; $d = & pbir -q batch run (Join-Path $brief 'build.batch.json') --plan-digest $digest --dry-run --json | ConvertFrom-Json; if (-not $d.ok) { throw 'dry run failed' }",
        "if ($DryRun) { Write-Host 'dry run ok; stopping (-DryRun)'; exit 0 }",
        "Step 'batch run'; $runJson = & pbir -q batch run (Join-Path $brief 'build.batch.json') --plan-digest $digest --json; $run = $runJson | ConvertFrom-Json",
        "[IO.File]::WriteAllText((Join-Path $brief 'build.run.json'), ($runJson -join \"`n\"), [Text.UTF8Encoding]::new($false))",
        "if (-not $run.ok) { $bad = $run.steps | Where-Object { $_.status -ne 'ok' } | Select-Object -First 3; throw \"batch run failed: $($bad | ConvertTo-Json -Compress -Depth 4)\" }",
        "Step 'post (sorts, filters)'; & pwsh -NoProfile -File (Join-Path $brief 'build.post.ps1'); if ($LASTEXITCODE -ne 0) { throw 'build.post.ps1 failed' }",
        "Step 'validate'; & pbir -q validate $r --all --json | Out-File -Encoding utf8NoBOM (Join-Path $brief 'build.validate.json'); Write-Host \"validate written to $(Join-Path $brief 'build.validate.json') (exit $LASTEXITCODE)\"",
        "Write-Host \"`nbuild complete - next: Invoke-VerifyLoop.ps1 -Report `\"$r`\" then pbi-visual-reviewer / pbi-spec-verifier\"",
    ]
    return {"layout": layout, "batch": batch, "pages_ps1": "\r\n".join(pages_cmds) + "\r\n", "post_ps1": "\r\n".join(post_cmds) + "\r\n",
            "run_ps1": "\r\n".join(run_cmds) + "\r\n"}, errors, warnings


def write_utf8(path: Path, text: str) -> None:
    path.write_bytes(text.encode("utf-8"))  # no BOM


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", required=True)
    ap.add_argument("--report", required=True, help='report path, e.g. "C:\\dev\\pbi\\Sales\\Sales.Report"')
    ap.add_argument("--out-dir", default=None, help="default: <spec dir> if it is named _brief, else ./_brief")
    ap.add_argument("--model-inventory", default=None)
    ap.add_argument("--pages-mode", choices=["create", "existing"], default=None, help="default from mode: greenfield=create, brownfield=existing")
    ap.add_argument("--emit-asserts", action="store_true")
    ap.add_argument("--strict", action="store_true", help="warnings become errors")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-schema-check", action="store_true", help="do not call pbir schema describe for color properties")
    args = ap.parse_args()

    spec = Path(args.spec)
    if not spec.exists():
        print(f"spec not found: {spec}", file=sys.stderr)
        return 2
    out_dir = Path(args.out_dir) if args.out_dir else (spec.parent if spec.parent.name == "_brief" else Path.cwd() / "_brief")
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        brief = load_brief(spec)
        inventory = load_inventory(Path(args.model_inventory)) if args.model_inventory else None
    except (ContractError, json.JSONDecodeError, yaml.YAMLError, OSError) as ex:
        print(f"error: {ex}", file=sys.stderr)
        return 2
    pages_mode = args.pages_mode or ("existing" if str(brief.get("mode", "")).lower() == "brownfield" else "create")
    result, errors, warnings = compile_contract(brief, args.report, inventory, pages_mode, args.emit_asserts, SchemaCheck(not args.no_schema_check))
    if args.strict and warnings and not errors:
        errors = [f"(strict) {w}" for w in warnings]
        result = None
    report_lines = [f"# Build report - {spec.name}", "", f"report: `{args.report}`  pages-mode: {pages_mode}", ""]
    if errors:
        report_lines += ["## Errors", ""] + [f"{i}. {e}" for i, e in enumerate(errors, 1)] + [""]
    if warnings:
        report_lines += ["## Warnings", ""] + [f"- {w}" for w in warnings] + [""]
    if result:
        for pg in result["layout"]["pages"]:
            report_lines += [f"## {pg['name']} ({pg['canvas']['width']}x{pg['canvas']['height']})", "", "| id | type | x | y | w | h | bindings |", "|---|---|---|---|---|---|---|"]
            for pl in pg["placements"]:
                b = ", ".join(f"{x['role']}:{x['field']}" for x in pl["bindings"]) or (pl.get("text") or "")
                report_lines.append(f"| {pl['id']} | {pl['visual_type']} | {pl['x']} | {pl['y']} | {pl['width']} | {pl['height']} | {b} |")
            report_lines.append("")
        report_lines += ["## Next", "", "1. `pwsh -NoProfile -File _brief/build.run.ps1 -DryRun` (validates the spec, creates pages, plans with digest, checks every create step resolves a target, dry-runs)",
                         "2. `pwsh -NoProfile -File _brief/build.run.ps1 -SkipPages` (real run + sorts/filters + validate)",
                         "3. `Invoke-VerifyLoop.ps1 -Report <report> -DesktopPid <pid>`, then dispatch pbi-visual-reviewer and pbi-spec-verifier",
                         "4. `uv run verify_spec.py --layout _brief/build.layout.json --report <report> --json`",
                         "", "Note: `pbir batch` resolves `root` only relative to the working directory; build.run.ps1 sets the cwd to the project folder.", ""]
    write_utf8(out_dir / "build.report.md", "\r\n".join(report_lines))
    if result:
        write_utf8(out_dir / "build.layout.json", json.dumps(result["layout"], indent=2))
        write_utf8(out_dir / "build.batch.json", json.dumps(result["batch"], indent=2))
        write_utf8(out_dir / "build.pages.ps1", result["pages_ps1"])
        write_utf8(out_dir / "build.post.ps1", result["post_ps1"])
        write_utf8(out_dir / "build.run.ps1", result["run_ps1"])
    summary = {"ok": not errors, "errors": errors, "warnings": warnings, "out_dir": str(out_dir),
               "files": ["build.report.md"] + (["build.layout.json", "build.batch.json", "build.pages.ps1", "build.post.ps1", "build.run.ps1"] if result else []),
               "pages": [{"name": p["name"], "placements": len(p["placements"])} for p in result["layout"]["pages"]] if result else []}
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        if errors:
            print("contract errors:")
            for i, e in enumerate(errors, 1):
                print(f"  {i}. {e}")
        for w in warnings:
            print(f"  warning: {w}")
        if result:
            for p in summary["pages"]:
                print(f"  page {p['name']}: {p['placements']} placements")
            print(f"  wrote {', '.join(summary['files'])} to {out_dir}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
