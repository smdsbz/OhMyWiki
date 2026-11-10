# Dump Template ns (10) + census across ns0/ns10/ns828: #invoke, parser
# functions, templatestyles, dpl — where the real expansion work lives.
import json
import re
import time
from collections import Counter
from pathlib import Path

from curl_cffi import requests

OUT = Path(__file__).parent / "out"
API = "https://zh.stardewvalleywiki.com/mediawiki/api.php"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")
DELAY = 3.0

s = requests.Session(impersonate="chrome", headers={"User-Agent": UA})


def q(**params):
    params["format"] = "json"
    for attempt in range(5):
        time.sleep(DELAY)
        r = s.get(API, params=params, timeout=40)
        if r.status_code == 200 and "json" in r.headers.get("content-type", ""):
            return r.json()
        wait = 20 * (attempt + 1)
        print(f"  ! HTTP {r.status_code}, wait {wait}s ({attempt + 1})", flush=True)
        time.sleep(wait)
    raise RuntimeError(f"API keeps failing: {r.status_code}")


def crawl_ns(ns, path):
    dump = OUT / path
    done = set()
    if dump.exists():
        for line in dump.read_text(encoding="utf-8").splitlines():
            try:
                done.add(json.loads(line)["title"])
            except Exception:
                pass
    cont = None
    while True:
        p = {"action": "query", "generator": "allpages", "gapnamespace": ns,
             "gaplimit": 50, "gapfilterredir": "nonredirects",
             "prop": "revisions", "rvprop": "content", "rvslots": "main"}
        if cont:
            p.update(cont)
        d = q(**p)
        with dump.open("a", encoding="utf-8") as f:
            for pg in d["query"]["pages"].values():
                t = pg["title"]
                if t in done or "revisions" not in pg:
                    continue
                c = pg["revisions"][0]["slots"]["main"]["*"]
                f.write(json.dumps({"title": t, "ns": ns, "size": len(c),
                                    "content": c}, ensure_ascii=False) + "\n")
                done.add(t)
        cont = d.get("continue")
        print(f"  ns{ns} ({path}): total={len(done)}", flush=True)
        if not cont:
            return done


def records(path):
    p = OUT / path
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines()]


def main():
    print("[1] crawling Template ns-10 wikitext ...")
    crawl_ns(10, "zh_templates_dump.jsonl")

    print("[2] census ns0 + ns10 + ns828 ...")
    invokes = Counter()
    pf = Counter()
    tpl_calls = Counter()
    tstyles = Counter()
    dpl = Counter()
    for rec in records("zh_pages.jsonl") + records("zh_templates_dump.jsonl"):
        c = rec["content"]
        for m in re.finditer(r"\{\{#invoke:\s*([^|}]+)", c):
            invokes[m.group(1).strip()] += 1
        for m in re.finditer(r"\{\{\s*#([a-z]+):", c):
            pf["#" + m.group(1)] += 1
        for m in re.finditer(r"<templatestyles\s+src=\"([^\"]+)\"", c):
            tstyles[m.group(1)] += 1
        for m in re.finditer(r"\{\{\s*#dpl:", c):
            dpl["ns%d" % rec["ns"]] += 1
        if rec["ns"] == 0:
            for m in re.finditer(r"\{\{\s*([^{}|#\n]+)", c):
                head = m.group(1).strip()
                if not head.startswith("#"):
                    tpl_calls[head] += 1

    mods_dumped = {r["title"] for r in records("zh_pages.jsonl") if r["ns"] == 828}
    invoked_mods = set("Module:" + k for k in invokes)
    stats = {
        "invoke_calls_total": sum(invokes.values()),
        "invoke_by_module": invokes.most_common(),
        "invoke_modules_missing_from_dump": sorted(invoked_mods - mods_dumped),
        "parser_functions": pf.most_common(),
        "templatestyles_src": tstyles.most_common(),
        "dpl_calls": dict(dpl),
        "ns0_top_templates": tpl_calls.most_common(20),
    }
    (OUT / "zh_census2.json").write_text(
        json.dumps(stats, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(stats, ensure_ascii=False, indent=1))
    print("OK")


if __name__ == "__main__":
    main()
