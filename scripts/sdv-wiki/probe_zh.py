# Probe zh.stardewvalleywiki.com MediaWiki API through Cloudflare using curl_cffi
# (Chrome TLS/JA3 impersonation). Outputs JSON facts + saves raw responses to out/.
import json
import sys
from pathlib import Path

from curl_cffi import requests

API = "https://zh.stardewvalleywiki.com/mediawiki/api.php"
OUT = Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")


def q(session, **params):
    params.setdefault("format", "json")
    r = session.get(API, params=params, timeout=30)
    if r.status_code != 200:
        raise RuntimeError(f"HTTP {r.status_code}: {r.text[:200]}")
    ct = r.headers.get("content-type", "")
    if "json" not in ct:
        raise RuntimeError(f"non-JSON content-type {ct}: {r.text[:200]}")
    return r.json()


def main():
    s = requests.Session(impersonate="chrome", headers={"User-Agent": UA})

    print("[1] siteinfo ...")
    si = q(s, action="query", meta="siteinfo",
           siprop="general|statistics|extensions|namespaces")
    (OUT / "siteinfo.json").write_text(json.dumps(si, ensure_ascii=False, indent=1),
                                       encoding="utf-8")
    g, st = si["query"]["general"], si["query"]["statistics"]
    exts = [e["name"] for e in si["query"].get("extensions", [])]
    print(f"  generator: {g['generator']}  wikiid: {g.get('wikiid')}  lang: {g.get('lang')}")
    print(f"  stats: pages={st['pages']} articles={st['articles']} files={st['images']} "
          f"edits={st['edits']} activeusers={st['activeusers']}")
    key = [n for n in exts if any(k in n for k in (
        "Semantic", "Scribunto", "DynamicPageList", "Cargo", "Variables",
        "Loops", "Arrays", "TemplateStyles", "Widgets", "Maps"))]
    print(f"  key extensions: {', '.join(key) if key else '(none)'}  [total {len(exts)}]")
    (OUT / "extensions.txt").write_text("\n".join(sorted(exts)), encoding="utf-8")

    ns = si["query"]["namespaces"]
    mod_ns = next((int(k) for k, v in ns.items()
                   if v.get("canonical") == "Module" or v.get("*") == "Module"), 827)

    print(f"[2] Module ns={mod_ns} count ...")
    mod = q(s, action="query", list="allpages", apnamespace=mod_ns,
            aplimit=500, apfilterredir="nonredirects")
    names = [p["title"] for p in mod["query"]["allpages"]]
    more = "continue" in mod
    print(f"  modules: {len(names)}{'+' if more else ''} e.g. {names[:6]}")

    print("[3] sample wikitext ...")
    samples = {}
    for title in ["Stardew Valley Wiki", "Villagers", "钓鱼", "Alex"]:
        try:
            rv = q(s, action="query", prop="revisions", titles=title,
                   rvprop="content|size", rvslots="main")
            page = next(iter(rv["query"]["pages"].values()))
            if "revisions" in page:
                c = page["revisions"][0]["slots"]["main"]["*"]
                samples[title] = {"size": page["revisions"][0]["size"],
                                  "head": c[:400]}
                print(f"  {title}: {page['revisions'][0]['size']} bytes")
            else:
                samples[title] = "MISSING"
                print(f"  {title}: MISSING (翻译未覆盖?)")
        except Exception as e:
            samples[title] = f"ERROR {e}"
            print(f"  {title}: ERROR {e}")
    (OUT / "samples.json").write_text(json.dumps(samples, ensure_ascii=False, indent=1),
                                      encoding="utf-8")

    print("[4] sample file url ...")
    files = q(s, action="query", list="allpages", apnamespace=6, aplimit=3,
              apfilterredir="nonredirects")
    t = files["query"]["allpages"][0]["title"]
    ii = q(s, action="query", titles=t, prop="imageinfo", iiprop="url|size|sha1")
    fp = next(iter(ii["query"]["pages"].values()))
    info = fp.get("imageinfo", [{}])[0]
    print(f"  {t} -> {info.get('url')}")
    print("OK")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"FAILED: {e}", file=sys.stderr)
        sys.exit(1)
