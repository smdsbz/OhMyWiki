# Full zh ns-0 wikitext mini-dump + usage statistics.
# Proves the crawl pipeline end-to-end and yields template/#invoke/File census.
import json
import re
import time
from collections import Counter
from pathlib import Path

from curl_cffi import requests

OUT = Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)
DUMP = OUT / "zh_pages.jsonl"
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


def crawl_ns(ns):
    done = set()
    if DUMP.exists():
        for line in DUMP.read_text(encoding="utf-8").splitlines():
            try:
                done.add(json.loads(line)["title"])
            except Exception:
                pass
    cont = None
    n_new = 0
    while True:
        p = {"action": "query", "generator": "allpages", "gapnamespace": ns,
             "gaplimit": 50, "gapfilterredir": "nonredirects",
             "prop": "revisions", "rvprop": "content|size", "rvslots": "main"}
        if cont:
            p.update(cont)
        d = q(**p)
        pages = d["query"]["pages"]
        with DUMP.open("a", encoding="utf-8") as f:
            for pg in pages.values():
                t = pg["title"]
                if t in done or "revisions" not in pg:
                    continue
                c = pg["revisions"][0]["slots"]["main"]["*"]
                f.write(json.dumps({"title": t, "ns": ns, "size": len(c),
                                    "content": c}, ensure_ascii=False) + "\n")
                done.add(t)
                n_new += 1
        cont = d.get("continue")
        print(f"  ns{ns}: total={len(done)} new={n_new}", flush=True)
        if not cont:
            break
    return done


def main():
    print("[1] crawling zh ns-0 wikitext ...")
    titles0 = crawl_ns(0)

    print("[2] crawling zh ns-828 (Module) wikitext ...")
    titles_mod = crawl_ns(828)

    print("[3] Template ns (10) titles only ...")
    tmpl, cont = [], None
    while True:
        p = {"action": "query", "list": "allpages", "apnamespace": 10,
             "aplimit": 500, "apfilterredir": "nonredirects"}
        if cont:
            p.update(cont)
        d = q(**p)
        tmpl += [x["title"] for x in d["query"]["allpages"]]
        cont = d.get("continue")
        if not cont:
            break
    (OUT / "zh_templates.json").write_text(json.dumps(tmpl), encoding="utf-8")

    print("[4] usage census over ns-0 pages ...")
    tpl_calls = Counter()
    invokes = Counter()
    files = set()
    smw = 0
    tables = 0
    total_bytes = 0
    n_pages = 0
    tpl_re = re.compile(r"\{\{\s*([^{}|#]+)")
    for line in DUMP.read_text(encoding="utf-8").splitlines():
        rec = json.loads(line)
        if rec["ns"] != 0:
            continue
        n_pages += 1
        total_bytes += rec["size"]
        c = rec["content"]
        tables += c.count("\n{|")
        for m in tpl_re.finditer(c):
            head = m.group(1).strip()
            if head.startswith("#invoke:"):
                parts = head.split(":")[1].split("|")
                invokes[parts[0].strip()] += 1
            elif head.startswith("#"):
                tpl_calls[head.split(":")[0]] += 1
            else:
                tpl_calls[head.split("|")[0].strip()] += 1
        for m in re.finditer(r"\[\[\s*(?:[Ff]ile|文件|圖像|Image)\s*:\s*([^\]|]+)", c):
            files.add(m.group(1).strip())
        smw += len(re.findall(r"#ask:|#show:|#set:|\[\[[^:\]]+::", c))

    stats = {
        "pages": n_pages,
        "total_wikitext_bytes": total_bytes,
        "templates_ns10_count": len(tmpl),
        "distinct_template_names_called": len(tpl_calls),
        "top_template_calls": tpl_calls.most_common(25),
        "parser_functions": {k: v for k, v in tpl_calls.items() if k.startswith("#")},
        "invoke_modules_called": invokes.most_common(),
        "distinct_files_referenced": len(files),
        "table_blocks": tables,
        "smw_marker_count": smw,
        "module_pages_dumped": len(titles_mod),
    }
    (OUT / "zh_usage_stats.json").write_text(
        json.dumps(stats, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({k: v for k, v in stats.items()
                      if k not in ("top_template_calls",)},
                     ensure_ascii=False, indent=1))
    print("OK")


if __name__ == "__main__":
    main()
