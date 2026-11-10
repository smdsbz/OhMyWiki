# Pack the sdv-zh site zip: pages/(Main|Template|Category|Module)/...,
# flat images/, manifest.json, summary.json. Layout mirrors rakuen dump.
import json
import re
import shutil
import zipfile
from pathlib import Path

OUT = Path(__file__).parent / "out"
DUMP = OUT / "sdv_full.jsonl"
IMGDIR = OUT / "sdv-images"
DATADIR = OUT / "sdv-datapages"
SITE = OUT / "sdv-zh"
ZIP = OUT / "sdv-zh.zip"

NS_DIR = {0: "Main", 10: "Template", 14: "Category", 828: "Module"}
RESERVED = {"CON", "PRN", "AUX", "NUL"} | {
    f"COM{i}" for i in range(1, 10)} | {f"LPT{i}" for i in range(1, 10)}


def sanitize_component(name: str) -> str:
    name = re.sub(r'[<>:"\\|?*]', "_", name)
    name = name.rstrip(" .") or "_"
    if name.upper() in RESERVED:
        name = "_" + name
    return name


def page_path(ns: int, title: str) -> str:
    # strip ns prefix from title (dir carries the ns)
    t = title.split(":", 1)[1] if ":" in title else title
    parts = [NS_DIR[ns]] + [sanitize_component(p) for p in t.split("/")]
    return "/".join(parts) + ".wiki"


def main():
    if SITE.exists():
        shutil.rmtree(SITE)
    (SITE / "pages").mkdir(parents=True)
    (SITE / "images").mkdir()

    used = {}  # path -> title (collision check)
    manifest = []

    def add_page(title: str, ns: int, pageid: int, content: str):
        path = page_path(ns, title)
        if path in used:
            base, ext = path[:-len(".wiki")], ".wiki"
            n = 2
            while f"{base}_dup{n}{ext}" in used:
                n += 1
            path = f"{base}_dup{n}{ext}"
            print(f"  ! path collision: {title} -> {path}")
        used[path] = title
        fp = SITE / "pages" / path
        fp.parent.mkdir(parents=True, exist_ok=True)
        data = content.encode("utf-8")
        fp.write_bytes(data)
        manifest.append({"title": title, "ns": ns, "pageid": pageid,
                         "path": path.replace("\\", "/"), "bytes": len(data)})

    for line in DUMP.read_text(encoding="utf-8").splitlines():
        rec = json.loads(line)
        add_page(rec["title"], rec["ns"], rec["pageid"], rec["content"])
    # synthetic data pages (Module:Data/<name>)
    for f in sorted(DATADIR.glob("*.wiki")):
        add_page(f"Module:Data/{f.stem}", 828, 0, f.read_text(encoding="utf-8"))

    n_img = 0
    img_bytes = 0
    for f in sorted(IMGDIR.iterdir()):
        if f.is_file():
            shutil.copy2(f, SITE / "images" / f.name)
            n_img += 1
            img_bytes += f.stat().st_size

    summary = {
        "site": "星露谷物语官方维库",
        "dbname": "zhwiki",
        "url": "https://zh.stardewvalleywiki.com",
        "format": "wikitext",
        "home_title": "Stardew Valley Wiki",
        "total_pages": len(manifest),
        "total_images": n_img,
    }
    (SITE / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    (SITE / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"pages: {len(manifest)}, images: {n_img} ({img_bytes/1e6:.1f} MB)")

    if ZIP.exists():
        ZIP.unlink()
    with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in sorted(SITE.rglob("*")):
            if p.is_file():
                z.write(p, p.relative_to(SITE).as_posix())
    print(f"zip: {ZIP} ({ZIP.stat().st_size/1e6:.1f} MB)")


if __name__ == "__main__":
    main()
