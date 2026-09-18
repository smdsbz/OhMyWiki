#!/usr/bin/env python3
"""Pack the MHXX site (github.com/AngryChocobo/monster-hunter-web-data) into an
OhMyWiki HTML-direct-render site zip.

Source of truth: ../mhxx-repo (git clone, never modified by this script).
Pipeline per page:
  read → apply_jquery (materialize $('.cls').html('...') injections)
       → extract meta (title from <title>, ns from #bread)
       → strip repeated chrome (<head>, #bread, #navi1, remaining <script>)
Output zip (flat root = site root):
  pages/index.html, pages/data/N.html, pages/ida/N.html   (cleaned originals)
  images/<original subdir structure>
  manifest.json  [{title, ns, pageid, path, bytes}]
  summary.json   {site, url, exported_at, total_pages, total_images, format}

The app renders these pages via the HTML path (MhxxSiteAdapter pageFormat='html');
no wikitext conversion happens here.

Usage (scripts/.venv):
  python pack.py               # pack from ../mhxx-repo
  python pack.py --repo PATH   # alternative repo checkout
"""

import argparse
import json
import re
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

import crawl  # noqa: E402  (reuse: apply_jquery, page_meta, JQ_RE)

OUT = Path(__file__).resolve().parent
REPO = OUT.parent / "mhxx-repo"
ZIP_PATH = OUT / "monster-hunter-web-data-html.zip"

# 站内页面白名单（与 crawl.normalize_link 一致）：cat.html 是 2832 页的重复聚合页，排除
PAGE_RE = re.compile(r"^(index\.html|(data|ida)/\d+\.html)$")

HEAD_RE = re.compile(r"<head[^>]*>.*?</head>", re.S)
BREAD_RE_STRIP = re.compile(r'<ul id="bread">.*?</ul>', re.S)
SCRIPT_RE = re.compile(r"<script[^>]*>.*?</script>", re.S)
DIV_TOKEN_RE = re.compile(r"<div\b[^>]*>|</div>", re.I)


def strip_element(text: str, start_match: re.Match) -> str:
    """从 start_match 起删除配平的 <div ...>...</div> 块（#navi1 内嵌多层 div）。"""
    depth = 0
    pos = start_match.start()
    for m in DIV_TOKEN_RE.finditer(text, pos):
        depth += 1 if not m.group(0).startswith("</") else -1
        if depth == 0:
            return text[:pos] + text[m.end():]
    raise ValueError(f"unbalanced div from offset {pos}")


def strip_chrome(text: str) -> str:
    # 顺序：先 head（含全部 head 内 script/style/link），再面包屑、导航块、残余内联 script
    text = HEAD_RE.sub("", text)
    text = BREAD_RE_STRIP.sub("", text)
    while True:
        m = re.search(r'<div id="navi1">', text)
        if m is None:
            break
        text = strip_element(text, m)
    text = SCRIPT_RE.sub("", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"


def count_injections(text: str) -> tuple[int, int]:
    """-> (注入语句数, 实际替换命中数)：不等说明有注入目标未找到（空标签缺失）。"""
    injections = {}
    for cls, raw in crawl.JQ_RE.findall(text):
        injections[cls] = crawl.unescape_js(raw)
    replaced = 0
    for cls, content in injections.items():
        pat = re.compile(
            r"<(\w+)([^>]*\bclass=\"[^\"]*\b" + re.escape(cls) + r"\b[^\"]*\"[^>]*)>\s*</\1>")
        text, n = pat.subn(lambda m: content, text)
        replaced += n
    return len(injections), replaced


def enumerate_pages(repo: Path) -> list[str]:
    rels = []
    if (repo / "index.html").exists():
        rels.append("index.html")
    for sub in ("data", "ida"):
        d = repo / sub
        if not d.is_dir():
            continue
        rels.extend(f"{sub}/{f.name}" for f in sorted(d.iterdir())
                    if f.is_file() and f.suffix == ".html")
    return [r for r in rels if PAGE_RE.match(r)]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", type=Path, default=REPO)
    args = ap.parse_args()
    repo = args.repo.resolve()
    if not (repo / "data").is_dir():
        sys.exit(f"repo not found: {repo}")

    rels = enumerate_pages(repo)
    print(f"pages: {len(rels)}")

    # pass 1: materialize + meta + link_map（标题冲突追加 pageid）
    cleaned: dict[str, str] = {}
    metas: dict[str, tuple[str, str, int]] = {}
    used: dict[str, str] = {}
    inj_total = repl_total = 0
    unmatched: list[str] = []
    for rel in rels:
        text = (repo / rel).read_text(encoding="utf-8")
        inj, repl = count_injections(text)
        text = crawl.apply_jquery(text)
        if inj != repl:
            unmatched.append(f"{rel} ({inj} injections, {repl} replaced)")
        inj_total += inj
        repl_total += repl
        ns, title, pid = crawl.page_meta(text, rel)
        key = f"{ns}:{title}"
        if key in used:
            title = f"{title}({pid})"
            key = f"{ns}:{title}"
        used[key] = rel
        metas[rel] = (ns, title, pid)
        cleaned[rel] = strip_chrome(text)
    if unmatched:
        print(f"WARN: jquery injections not fully materialized on {len(unmatched)} pages:")
        for u in unmatched[:10]:
            print(f"  {u}")
    print(f"jquery injections: {inj_total} declared, {repl_total} materialized")

    # manifest（title 形态与旧 wikitext 转储一致：非 Main 空间带 "ns:" 前缀）
    manifest = []
    for rel in rels:
        ns, title, pid = metas[rel]
        body = cleaned[rel]
        manifest.append({
            "title": title if ns == "Main" else f"{ns}:{title}",
            "ns": 0 if ns == "Main" else 100,
            "pageid": pid,
            "path": rel,
            "bytes": len(body.encode("utf-8")),
        })
    titles = [m["title"] for m in manifest]
    assert len(titles) == len(set(titles)), "duplicate titles in manifest"

    images = sorted(str(p.relative_to(repo / "images")).replace("\\", "/")
                    for p in (repo / "images").rglob("*") if p.is_file())

    summary = {
        "site": "怪物猎人XX攻略大全",
        "url": crawl.SITE,
        "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "total_pages": len(manifest),
        "total_images": len(images),
        "format": "html",
    }

    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel in rels:
            z.writestr(f"pages/{rel}", cleaned[rel])
        for rel in images:
            z.write(repo / "images" / rel, f"images/{rel}")
        z.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False))
        z.writestr("summary.json", json.dumps(summary, ensure_ascii=False, indent=2))

    raw_kb = sum((repo / r).stat().st_size for r in rels) // 1024
    print(f"pages packed: {len(rels)} (raw {raw_kb} KB -> cleaned "
          f"{sum(m['bytes'] for m in manifest) // 1024} KB)")
    print(f"images packed: {len(images)}")
    print(f"zip: {ZIP_PATH} ({ZIP_PATH.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
