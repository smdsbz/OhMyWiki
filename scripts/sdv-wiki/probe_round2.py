# Round 2: en/zh siteinfo comparison, full ns-0 title census both sides,
# en->zh langlinks translation coverage, zh sample wikitext inspection.
import json
import time
from pathlib import Path

from curl_cffi import requests

OUT = Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)

SITES = {
    "en": "https://stardewvalleywiki.com/mediawiki/api.php",
    "zh": "https://zh.stardewvalleywiki.com/mediawiki/api.php",
}
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")
DELAY = 3.0  # seconds between API calls (CF rate-limit guard)


def mk(api):
    return requests.Session(impersonate="chrome", headers={"User-Agent": UA})


def q(session, api, **params):
    params["format"] = "json"
    for attempt in range(4):
        time.sleep(DELAY)
        r = session.get(api, params=params, timeout=30)
        if r.status_code == 200 and "json" in r.headers.get("content-type", ""):
            return r.json()
        wait = 15 * (attempt + 1)
        print(f"    ! HTTP {r.status_code}, backoff {wait}s (attempt {attempt + 1})")
        time.sleep(wait)
    raise RuntimeError(f"API keeps failing: HTTP {r.status_code}")


def allpages(sess, api, ns=0):
    titles, cont = [], None
    while True:
        p = {"action": "query", "list": "allpages", "apnamespace": ns,
             "aplimit": 500, "apfilterredir": "nonredirects"}
        if cont:
            p.update(cont)
        d = q(sess, api, **p)
        titles += [x["title"] for x in d["query"]["allpages"]]
        cont = d.get("continue")
        if not cont:
            return titles


def main():
    en, zh = mk(SITES["en"]), mk(SITES["zh"])

    print("[1] en siteinfo ...")
    esi = q(en, SITES["en"], action="query", meta="siteinfo",
            siprop="general|statistics|extensions")
    g, st = esi["query"]["general"], esi["query"]["statistics"]
    exts = [e["name"] for e in esi["query"].get("extensions", [])]
    sem = [n for n in exts if "Semantic" in n]
    print(f"  {g['generator']} wikiid={g.get('wikiid')} pages={st['pages']} "
          f"articles={st['articles']} files={st['images']} activeusers={st['activeusers']}")
    print(f"  SMW: {sem or 'ABSENT'}")
    (OUT / "en_extensions.txt").write_text("\n".join(sorted(exts)), encoding="utf-8")

    print("[2] cookies after session (CF clearance check) ...")
    for name, s in (("en", en), ("zh", zh)):
        q(s, SITES[name], action="query", meta="siteinfo", siprop="general")
        cf = [c.name for c in s.cookies.jar]
        print(f"  {name}: cookies={cf or '(none)'}")

    print("[3] full ns-0 titles ...")
    if (OUT / "en_titles.json").exists() and (OUT / "zh_titles.json").exists():
        en_titles = json.loads((OUT / "en_titles.json").read_text(encoding="utf-8"))
        zh_titles = json.loads((OUT / "zh_titles.json").read_text(encoding="utf-8"))
        print("  (cached)")
    else:
        en_titles = allpages(en, SITES["en"])
        zh_titles = allpages(zh, SITES["zh"])
        (OUT / "en_titles.json").write_text(json.dumps(en_titles), encoding="utf-8")
        (OUT / "zh_titles.json").write_text(json.dumps(zh_titles), encoding="utf-8")
    print(f"  en={len(en_titles)}  zh={len(zh_titles)}")

    print("[4] en->zh langlinks coverage (generator, 500/req) ...")
    en_titles_zh = {}
    cont = None
    while True:
        p = {"action": "query", "generator": "allpages", "gapnamespace": 0,
             "gaplimit": 500, "gapfilterredir": "nonredirects",
             "prop": "langlinks", "lllang": "zh", "lllimit": 500}
        if cont:
            p.update(cont)
        d = q(en, SITES["en"], **p)
        for pg in d["query"]["pages"].values():
            if pg.get("langlinks"):
                en_titles_zh[pg["title"]] = pg["langlinks"][0]["*"]
        cont = d.get("continue")
        print(f"    cum={len(en_titles_zh)}")
        if not cont:
            break
    missing = [t for t in en_titles if t not in en_titles_zh]
    (OUT / "en_zh_map.json").write_text(
        json.dumps(en_titles_zh, ensure_ascii=False), encoding="utf-8")
    (OUT / "en_zh_missing.json").write_text(
        json.dumps(missing, ensure_ascii=False), encoding="utf-8")
    print(f"  translated: {len(en_titles_zh)}/{len(en_titles)} "
          f"({100*len(en_titles_zh)/len(en_titles):.1f}%)  missing: {len(missing)}")

    print("[5] zh titles without en langlink (zh-only pages) ...")
    zh_set = set(zh_titles)
    zh_mapped_targets = set(en_titles_zh.values())
    zh_only = zh_set - zh_mapped_targets
    print(f"  zh-only: {len(zh_only)} e.g. {sorted(zh_only)[:8]}")

    print("[6] zh sample wikitext template usage (钓鱼) ...")
    rv = q(zh, SITES["zh"], action="query", prop="revisions",
           titles="钓鱼", rvprop="content", rvslots="main")
    page = next(iter(rv["query"]["pages"].values()))
    c = page["revisions"][0]["slots"]["main"]["*"]
    (OUT / "zh_fishing.wiki").write_text(c, encoding="utf-8")
    print(f"  saved zh_fishing.wiki ({len(c)} bytes); head:")
    print("  " + c[:300].replace("\n", "\n  "))

    print("OK")


if __name__ == "__main__":
    main()
