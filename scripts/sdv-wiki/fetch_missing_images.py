# Coverage check: wikitext File references (ns 0/10/828) vs extracted images.
# Missing files are resolved via zh api.php imageinfo (en repo proxy) and downloaded.
import json
import re
import time
from pathlib import Path

from curl_cffi import requests

OUT = Path(__file__).parent / "out"
IMGDIR = OUT / "sdv-images"
DUMP = OUT / "sdv_full.jsonl"
API = "https://zh.stardewvalleywiki.com/mediawiki/api.php"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")
DELAY = 3.0

s = requests.Session(impersonate="chrome", headers={"User-Agent": UA})


def q(api: str | None = None, **params):
    params["format"] = "json"
    base = api if api else API
    for attempt in range(6):
        time.sleep(DELAY)
        r = s.post(base, data=params, timeout=40)
        if r.status_code == 200 and "json" in r.headers.get("content-type", ""):
            return r.json()
        wait = 20 * (attempt + 1)
        print(f"  ! HTTP {r.status_code}, wait {wait}s ({attempt + 1})", flush=True)
        time.sleep(wait)
    raise RuntimeError(f"API keeps failing: {r.status_code}")


def norm(name: str) -> str:
    # engine probe candidates: original / underscores / case swap; illegal -> _
    n = name.replace(" ", "_")
    for ch in '<>:"\\|?*':
        n = n.replace(ch, "_")
    if n and n[0].isalpha():
        n2 = n[0].lower() + n[1:] if n[0].isupper() else n[0].upper() + n[1:]
    else:
        n2 = n
    return n


def main():
    # 1. referenced set from all wikitext
    refs = set()
    pat = re.compile(r"\[\[\s*(?:文件|File|圖像|Image|图像)\s*:\s*([^\]|\n]+)")
    gal = re.compile(r"^[ \t]*(?:文件|File|圖像|Image|图像)\s*:\s*([^\]|\n]+)",
                     re.M)
    n_recs = 0
    for line in DUMP.read_text(encoding="utf-8").splitlines():
        rec = json.loads(line)
        c = rec["content"]
        n_recs += 1
        for m in pat.finditer(c):
            refs.add(m.group(1).strip())
        for m in gal.finditer(c):
            refs.add(m.group(1).strip())
    print(f"scanned {n_recs} records -> {len(refs)} distinct file refs")

    # 2. existing images index
    have = {}
    for f in IMGDIR.iterdir():
        if f.is_file():
            have[norm(f.name)] = f.name
    print(f"extracted images: {len(have)}")

    # 3. missing (skip template-parameter artifacts: {{{...}}}, {{...}}, #)
    missing = []
    for r in sorted(refs):
        if any(ch in r for ch in "{}#<>"):
            continue
        if norm(r) not in have:
            missing.append(r)
    print(f"missing after ZIM (template artifacts filtered): {len(missing)}")
    for m in missing[:20]:
        print("  e.g.", m)
    if not missing:
        (OUT / "sdv-images-missing.json").write_text("[]", encoding="utf-8")
        return
    (OUT / "sdv-images-missing.json").write_text(
        json.dumps(missing, ensure_ascii=False), encoding="utf-8")

    # 4. resolve via imageinfo + download (zh first, then en repo fallback)
    EN_API = "https://stardewvalleywiki.com/mediawiki/api.php"
    fetched = failed = 0
    for i in range(0, len(missing), 40):
        chunk = [f"File:{m}" for m in missing[i:i + 40]]
        d = q(action="query", titles="|".join(chunk), prop="imageinfo",
              iiprop="url|size|mime")
        for pg in d["query"]["pages"].values():
            title = pg.get("title", "?")
            name = title[5:] if title.startswith("File:") else title
            if "missing" in pg or "imageinfo" not in pg:
                # zh foreign repo miss -> ask en directly
                de = q(EN_API, action="query", titles=title, prop="imageinfo",
                       iiprop="url|size|mime")
                dp = next(iter(de["query"]["pages"].values()))
                if "missing" in dp or "imageinfo" not in dp:
                    print(f"  ? dead ref (zh+en both miss): {name}")
                    failed += 1
                    continue
                pg = dp
            info = pg["imageinfo"][0]
            url = info["url"]
            dest = IMGDIR / norm(name)
            if dest.exists() and dest.stat().st_size == info.get("size", -1):
                fetched += 1
                continue
            for attempt in range(4):
                time.sleep(1.5)
                r = s.get(url, timeout=60)
                if r.status_code == 200:
                    dest.write_bytes(r.content)
                    fetched += 1
                    break
                print(f"  ! img HTTP {r.status_code} {url}, retry")
                time.sleep(15)
            else:
                failed += 1
        print(f"  {min(i + 40, len(missing))}/{len(missing)} "
              f"(fetched {fetched}, failed {failed})", flush=True)
    print(f"done: fetched {fetched}, failed {failed}, "
          f"images now {len(list(IMGDIR.iterdir()))}")


if __name__ == "__main__":
    main()
