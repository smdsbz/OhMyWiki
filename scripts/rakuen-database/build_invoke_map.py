#!/usr/bin/env python3
"""Build the three-layer dependency map: page -> #invoke -> module -> data source.

Reads the exported pages/ tree and produces invoke_map.json:

  Layer 1  page -> [(module, function, args)]            # direct + via-template
  Layer 2  module -> {json prefixes (loadJson),           # dump-covered data
                      xbdb tables (QueryHelper -> SQL)}
  Layer 3  SQL table <-> JSON namespace dir mapping       # which tables exist in the dump

Per-page verdict: "local" (all data in dump) or "snapshot" (xbdb gap -> needs action=parse HTML).

Usage:
  python build_invoke_map.py                 # writes invoke_map.json in project root
"""
import json
import re
from pathlib import Path

OUT = Path(__file__).resolve().parent
PAGES_DIR = OUT / "pages"
INVOKE_MAP = OUT / "invoke_map.json"

REQUIRE_RE = re.compile(r'require\("Module:(\w+)"\)')
INVOKE_RE = re.compile(
    r"\{\{#invoke:([^\|}]+)\|([^\|}]+)"
    r"((?:[^{}]|(?:\{\{\{[^{}]*\}\}\}))*?)\}\}")
LOADJSON_RE = re.compile(r'loadJson\(\s*"([^"]*)"(\s*\.\.\s*(.*?))?\s*\)')
QUERYHELPER_RE = re.compile(r"QueryHelper\.(\w+)\s*\(")
FUNC_RE = re.compile(r"function\s+p\.(\w+)\s*\(")
FROM_RE = re.compile(r'FROM\s+"?([A-Za-z_]+)"?', re.IGNORECASE)


def norm(name: str) -> str:
    return re.sub(r"\s+", " ", name.lower().replace("_", " ")).strip()


def _shared_prefix(a: str, b: str) -> int:
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def load_json_dirs() -> dict:
    """Map normalized JSON-table-name -> actual dir name, plus top-level files."""
    mapping = {}
    json_root = PAGES_DIR / "JSON"
    for d in json_root.iterdir():
        if d.is_dir():
            mapping[norm(d.name)] = d.name
    for f in json_root.glob("*.wiki"):
        mapping[norm(f.stem)] = f.stem
    return mapping


def scan_invokes() -> dict:
    """Layer 1: page path -> list of (module, function, args)."""
    invokes = {}
    for f in sorted(PAGES_DIR.rglob("*.wiki")):
        rel = f.relative_to(PAGES_DIR).as_posix()
        hits = []
        for m in INVOKE_RE.finditer(f.read_text(encoding="utf-8")):
            args = [a.strip() for a in m.group(3).split("|") if a.strip()]
            hits.append({"module": m.group(1).strip(), "fn": m.group(2).strip(),
                         "args": args})
        if hits:
            invokes[rel] = hits
    return invokes


def scan_modules(json_dirs: dict) -> dict:
    """Layer 2: module file -> {json prefixes, query helper calls, xbdb tables}.

    xbdb tables are propagated transitively through require("Module:X") chains
    (e.g. Npc requires Condition which queries FLD_ConditionList).
    """
    raw = {}
    helper_tables = scan_query_helper_tables()
    for f in sorted((PAGES_DIR / "模块").glob("*.wiki")):
        text = f.read_text(encoding="utf-8")
        json_pre = sorted({m.group(1) for m in LOADJSON_RE.finditer(text)})
        helpers = sorted({m.group(1) for m in QUERYHELPER_RE.finditer(text)})
        requires = sorted({m.group(1) for m in REQUIRE_RE.finditer(text)})
        xbdb = sorted({t for h in helpers for t in helper_tables.get(h, [])})
        raw[f.stem] = {"json_prefixes": json_pre, "helpers": helpers,
                       "requires": requires, "xbdb": xbdb}
    mods = {}
    for name in raw:
        seen, stack = {name}, list(raw[name]["requires"])
        while stack:
            dep = stack.pop()
            if dep in seen or dep not in raw:
                continue
            seen.add(dep)
            stack.extend(raw[dep]["requires"])
        xbdb = sorted({t for d in seen for t in raw[d]["xbdb"]})
        json_pre = sorted({p for d in seen for p in raw[d]["json_prefixes"]})
        mods[name] = {"json_prefixes": json_pre,
                      "helpers": raw[name]["helpers"],
                      "requires": raw[name]["requires"],
                      "xbdb": xbdb}
    return mods


def scan_query_helper_tables() -> dict:
    """Map each QueryHelper.getXxx function to its SQL tables.

    Tables may be quoted, span lines after FROM, or be dynamic string
    concatenations (e.g. "BTL_Skill_Dr_Table" .. driverId .. ".*").
    """
    f = PAGES_DIR / "模块" / "Xb2QueryHelper.wiki"
    text = f.read_text(encoding="utf-8")
    blocks = {}
    names = list(FUNC_RE.finditer(text))
    for i, m in enumerate(names):
        end = names[i + 1].start() if i + 1 < len(names) else len(text)
        body = text[m.end():end]
        tables = set()
        for tm in re.finditer(r'FROM\s*"?([A-Za-z_][A-Za-z_0-9]*)"?', body,
                              re.IGNORECASE | re.DOTALL):
            name = tm.group(1)
            if name.lower() in ("select", "where", "join"):
                continue
            if ".." in body[tm.end():tm.end() + 24]:
                name += "_<dynamic>"
            tables.add(name)
        blocks[m.group(1)] = sorted(tables)
    return blocks


def classify(json_dirs: dict, sql_tables: set) -> dict:
    """Layer 3: SQL table -> json dir match / similar / gap."""
    out = {}
    for t in sorted(sql_tables):
        nt = norm(t)
        direct = json_dirs.get(nt)
        if direct:
            out[t] = {"json_dir": direct, "status": "covered"}
            continue
        similar = [d for d in json_dirs
                   if nt in d or d in nt
                   or _shared_prefix(nt, d) >= 8]
        out[t] = {"json_dir": None,
                  "similar": sorted(similar) if similar else [],
                  "status": "gap" if not similar else "review"}
    return out


def main():
    json_dirs = load_json_dirs()
    invokes = scan_invokes()
    mods = scan_modules(json_dirs)

    all_tables = {t for m in mods.values() for t in m["xbdb"]}
    tables = classify(json_dirs, all_tables)

    mods_by_lower = {k.lower(): k for k in mods}

    # Handler index: (module|fn) -> render logic entry. This is the O(1)
    # lookup table the renderer uses when it meets {{#invoke:...}} in a page.
    handlers = {}
    for rel, hits in invokes.items():
        for h in hits:
            mod_name = mods_by_lower.get(h["module"].lower(), h["module"])
            mod = mods.get(mod_name, {"json_prefixes": [], "xbdb": []})
            key = f"{mod_name}|{h['fn']}"
            gap = [t for t in mod["xbdb"]
                   if tables.get(t, {}).get("status") in ("gap", "review")]
            handler = {
                "fn": h["fn"],
                "json_prefixes": mod["json_prefixes"],
                "xbdb": mod["xbdb"],
                "xbdb_gap": gap,
                "render": "snapshot" if gap else "local",
            }
            if key in handlers:
                handlers[key]["pages"].append(rel)
            else:
                handler["pages"] = [rel]
                handlers[key] = handler

    for key, v in handlers.items():
        v["pages"] = sorted(set(v["pages"]))

    # Per-page entry: just the handler keys it invokes (renderer never scans).
    pages_out = {}
    for rel, hits in invokes.items():
        keys = []
        for h in hits:
            mod_name = mods_by_lower.get(h["module"].lower(), h["module"])
            keys.append({"invoke": f"{h['module']}|{h['fn']}",
                         "handler": f"{mod_name}|{h['fn']}",
                         "args": h["args"]})
        pages_out[rel] = keys

    snap = sorted({k for k, v in handlers.items() if v["render"] == "snapshot"})
    local = sorted({k for k, v in handlers.items() if v["render"] == "local"})

    doc = {
        "generated_at": __import__("time").strftime("%Y-%m-%dT%H:%M:%S"),
        "summary": {
            "pages_with_invoke": len(pages_out),
            "invoke_calls": sum(len(v) for v in pages_out.values()),
            "handlers_total": len(handlers),
            "handlers_local": len(local),
            "handlers_snapshot": len(snap),
            "handlers_snapshot_list": snap,
        },
        "json_tables_in_dump": sorted(json_dirs.keys()),
        "sql_tables": tables,
        "handlers": handlers,
        "pages": pages_out,
    }
    INVOKE_MAP.write_text(json.dumps(doc, ensure_ascii=False, indent=1),
                          encoding="utf-8")

    print("== summary ==")
    print(f"  pages with #invoke : {len(pages_out)}  (calls: {doc['summary']['invoke_calls']})")
    print(f"  handlers total     : {len(handlers)}  (local: {len(local)}, "
          f"snapshot: {len(snap)})")
    print()
    print("== xbdb-only tables (gap) and their consumers ==")
    for t, info in tables.items():
        if info["status"] == "gap":
            users = sorted({m for m, d in mods.items() if t in d["xbdb"]})
            print(f"  {t:22s} <- {users}")
    print()
    print("== ambiguous tables (similar dir exists, manual review) ==")
    for t, info in tables.items():
        if info["status"] == "review":
            print(f"  {t:22s} ~ {info['similar']}")
    print()
    print(f"written: {INVOKE_MAP}")


if __name__ == "__main__":
    main()
