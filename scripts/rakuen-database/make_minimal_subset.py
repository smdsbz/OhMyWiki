#!/usr/bin/env python3
"""Build a MINIMAL subset for emulator smoke testing (~20 files)."""
import json
import shutil
from pathlib import Path

SRC = Path(__file__).resolve().parent
OUT = Path(r"C:\Users\69406\Documents\Projects\ohmywiki-mini")
ENEMY_NAME = "一骑当千的萨克森"

PAGES = [
    "Main/首页.wiki",
    "Main/异刃.wiki",
    "Main/普通敌人.wiki",
    "Main/战斗系统.wiki",
    "Main/流程攻略.wiki",
    f"敌人/{ENEMY_NAME}.wiki",
    "异刃/焰.wiki",
    "模板/Enemy.wiki",
    "模板/BladeInfo.wiki",
    "模板/返回.wiki",
    "模板/剧透.wiki",
    "JSON/EnemyIdMap.wiki",
    "JSON/EnemyCategory.wiki",
]

IMAGES = [
    f"敌人-{ENEMY_NAME}.jpg",
    "fim_bl_001_0.png",
    "简体logo.png",
    "Wiki_logo.png",
]

def load_json(rel: str):
    p = SRC / "pages" / rel
    if not p.exists():
        return None
    return json.loads(p.read_text(encoding="utf-8"))

def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "pages").mkdir(parents=True)
    (OUT / "images").mkdir(parents=True)

    copied = []
    for rel in PAGES:
        src = SRC / "pages" / rel
        if not src.is_file():
            print("  MISSING PAGE:", rel)
            continue
        dst = OUT / "pages" / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied.append(rel)

    # JSON data for the enemy page (resolve deps)
    idmap = load_json("JSON/EnemyIdMap.wiki")
    eid = None
    if idmap:
        entry = idmap.get(ENEMY_NAME)
        if entry:
            first = entry[0]
            eid = first.get("id") if isinstance(first, dict) else first
    print("  enemy id:", eid)
    if eid:
        arr = load_json(f"JSON/CHR EnArrange/{eid}.wiki")
        if arr:
            copied.append(f"JSON/CHR EnArrange/{eid}.wiki")
            dst = OUT / "pages" / f"JSON/CHR EnArrange/{eid}.wiki"
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SRC / "pages" / f"JSON/CHR EnArrange/{eid}.wiki", dst)
            param_id = arr.get("ParamID")
            lv = arr.get("Lv")
            for rel in [f"JSON/CHR EnParam/{param_id}.wiki", f"JSON/CHR EnParamTable/{lv}.wiki",
                        f"JSON/BTL Grow/{lv}.wiki"]:
                p = SRC / "pages" / rel
                if p.is_file():
                    copied.append(rel)
                    dst = OUT / "pages" / rel
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(p, dst)
            param = load_json(f"JSON/CHR EnParam/{param_id}.wiki")
            if param:
                rid = param.get("ResourceID")
                rel = f"JSON/RSC En/{rid}.wiki"
                p = SRC / "pages" / rel
                if p.is_file():
                    copied.append(rel)
                    dst = OUT / "pages" / rel
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(p, dst)

    for name in IMAGES:
        src = SRC / "images" / name
        if src.is_file():
            shutil.copy2(src, OUT / "images" / name)
        else:
            print("  MISSING IMAGE:", name)

    # filtered manifest
    manifest = json.loads((SRC / "manifest.json").read_text(encoding="utf-8"))
    keep = [e for e in manifest if e.get("path") in copied]
    (OUT / "manifest.json").write_text(json.dumps(keep, ensure_ascii=False, indent=1), encoding="utf-8")
    shutil.copy2(SRC / "summary.json", OUT / "summary.json")
    print(f"copied {len(copied)} pages, manifest {len(keep)} entries")

if __name__ == "__main__":
    main()
