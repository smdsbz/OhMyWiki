#!/usr/bin/env python3
"""Build a small subset of rakuen-database for emulator smoke testing.

Output layout mirrors the real dump so the app can read it:
  <out>/
    summary.json
    manifest.json          (filtered to copied pages)
    pages.jsonl
    pages/<ns>/.../<title>.wiki
    images/<file>
"""
import json
import shutil
from pathlib import Path

SRC = Path(__file__).resolve().parent
OUT = Path(r"C:\Users\69406\Documents\Projects\ohmywiki-testdata")

# Namespaces copied fully
FULL_NS = ["Main", "模板", "JSON", "分类"]
# Extra specific pages (relative to pages/)
EXTRA_PAGES = [
    "敌人/一骑当千的萨克森.wiki",
    "敌人/珍稀种敌人.wiki",
    "异刃/焰.wiki",
    "异刃/光.wiki",
]
# Extra images (relative to images/)
EXTRA_IMAGES = [
    "敌人-一骑当千的萨克森.jpg",
    "简体logo.png",
    "Wiki_logo.png",
    "fim_bl_001_0.png",
    "异刃_homura.png",
    "异刃_hikari.png",
]

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    pages_src = SRC / "pages"
    pages_dst = OUT / "pages"
    images_src = SRC / "images"
    images_dst = OUT / "images"

    # clean out
    if pages_dst.exists():
        shutil.rmtree(pages_dst)
    if images_dst.exists():
        shutil.rmtree(images_dst)
    pages_dst.mkdir(parents=True)
    images_dst.mkdir(parents=True)

    copied = []

    def copy_one(rel: str):
        src = pages_src / rel
        if not src.is_file():
            print("  MISSING PAGE:", rel)
            return
        dst = pages_dst / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied.append(rel)

    # full namespaces
    for ns in FULL_NS:
        ns_dir = pages_src / ns
        if not ns_dir.exists():
            print("  MISSING NS:", ns)
            continue
        for p in sorted(ns_dir.rglob("*.wiki")):
            copy_one(p.relative_to(pages_src).as_posix())

    for rel in EXTRA_PAGES:
        copy_one(rel)

    # images
    for name in EXTRA_IMAGES:
        src = images_src / name
        if src.is_file():
            shutil.copy2(src, images_dst / name)
        else:
            print("  MISSING IMAGE:", name)

    # filtered manifest
    manifest = json.loads((SRC / "manifest.json").read_text(encoding="utf-8"))
    keep = []
    for entry in manifest:
        p = entry.get("path")
        if p and p in copied:
            keep.append(entry)
    (OUT / "manifest.json").write_text(json.dumps(keep, ensure_ascii=False, indent=1), encoding="utf-8")

    shutil.copy2(SRC / "summary.json", OUT / "summary.json")
    shutil.copy2(SRC / "pages.jsonl", OUT / "pages.jsonl")

    print(f"copied {len(copied)} pages, manifest kept {len(keep)} entries")

if __name__ == "__main__":
    main()
