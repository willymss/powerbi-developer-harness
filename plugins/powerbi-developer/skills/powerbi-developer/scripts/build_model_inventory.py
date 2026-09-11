"""Build _brief/model-inventory.json from a TMDL folder (offline, stdlib). Used by phase 2 when te / MCP are
unavailable, and as the compiler's field check input.

  uv run build_model_inventory.py --model "C:\\dev\\pbi\\Sales\\Sales.SemanticModel" [--out _brief/model-inventory.json] [--json]

Output: {"source": "<definition folder>", "tables": [{"name", "hidden", "columns": [..], "measures": [..], "dot_prefixed": bool}]}
Only names are parsed (table / column / measure / calculated column headers); expressions are ignored.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

NAME_RX = re.compile(r"""^(?P<indent>\s*)(?P<kind>table|column|measure)\s+(?P<name>'[^']+'|"[^"]+"|[^\s=]+)""", re.I)


def unquote(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        return s[1:-1]
    return s


def parse_tmdl(text: str) -> list[dict]:
    tables: list[dict] = []
    current: dict | None = None
    for line in text.splitlines():
        m = NAME_RX.match(line)
        if not m:
            if current is not None and re.match(r"^\s+isHidden\b", line) and current.get("_last") is None:
                current["hidden"] = True
            continue
        kind = m.group("kind").lower()
        name = unquote(m.group("name"))
        if kind == "table" and not m.group("indent"):
            current = {"name": name, "hidden": False, "columns": [], "measures": [], "dot_prefixed": name.startswith("."), "_last": None}
            tables.append(current)
        elif current is not None and kind == "column":
            current["columns"].append(name)
            current["_last"] = "column"
        elif current is not None and kind == "measure":
            current["measures"].append(name)
            current["_last"] = "measure"
    for t in tables:
        t.pop("_last", None)
    return tables


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, help=".SemanticModel folder (or its definition folder)")
    ap.add_argument("--out", default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    root = Path(args.model)
    definition = root / "definition" if (root / "definition").exists() else root
    tables_dir = definition / "tables"
    if not tables_dir.exists():
        print(f"no tables folder under {definition}", file=sys.stderr)
        return 2
    tables: list[dict] = []
    for f in sorted(tables_dir.glob("*.tmdl")):
        try:
            tables.extend(parse_tmdl(f.read_text(encoding="utf-8-sig")))
        except Exception as ex:  # pragma: no cover
            print(f"skip {f.name}: {ex}", file=sys.stderr)
    inv = {"source": str(definition), "tables": tables,
           "summary": {"tables": len(tables), "columns": sum(len(t["columns"]) for t in tables), "measures": sum(len(t["measures"]) for t in tables),
                       "dot_prefixed_tables": [t["name"] for t in tables if t["dot_prefixed"]]}}
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(json.dumps(inv, indent=2).encode("utf-8"))
    if args.json or not args.out:
        print(json.dumps(inv["summary"] if not args.json else inv, indent=2))
    else:
        s = inv["summary"]
        print(f"{s['tables']} tables, {s['columns']} columns, {s['measures']} measures -> {args.out}")
        if s["dot_prefixed_tables"]:
            print("dot-prefixed tables (unbindable via pbir): " + ", ".join(s["dot_prefixed_tables"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
