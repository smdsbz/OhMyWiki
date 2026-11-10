# Full zh dump: ns 0/10/828/14 including redirects, with pageid.
# Output: out/sdv_full.jsonl  {title, ns, pageid, redirect, size, content}
import json
import time
from pathlib import Path

from curl_cffi import requests

OUT = Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)
DUMP = OUT / "sdv_full.jsonl"
API = "https://zh.stardewvalleywiki.com/mediawiki/api.php"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")
DELAY = 3.0
NS_LIST = [0, 10, 828, 14]

s = requests.Session(impersonate="chrome", headers={"User-Agent": UA})


def q(**params):
    params["format"] = "json"
    for attempt in range(6):
        time.sleep(DELAY)
        r = s.get(API, params=params, timeout=40)
        if r.status_code == 200 and "json" in r.headers.get("content-type", ""):
            return r.json()
        wait = 20 * (attempt + 1)
        print(f"  ! HTTP {r.status_code}, wait {wait}s ({attempt + 1})", flush=True)
        time.sleep(wait)
    raise RuntimeError(f"API keeps failing: {r.status_code}")


def crawl():
    done = {}  # title -> record
    if DUMP.exists():
        for line in DUMP.read_text(encoding="utf-8").splitlines():
            try:
                rec = json.loads(line)
                done[rec["title"]] = rec
            except Exception:
                pass
    with DUMP.open("a", encoding="utf-8") as out_f:
        for ns in NS_LIST:
            todo_titles = []
            cont = None
            while True:
                p = {"action": "query", "list": "allpages", "apnamespace": ns,
                     "aplimit": 500}
                if cont:
                    p.update(cont)
                d = q(**p)
                todo_titles += [x["title"] for x in d["query"]["allpages"]]
                cont = d.get("continue")
                if not cont:
                    break
            print(f"ns{ns}: {len(todo_titles)} titles (incl redirects)", flush=True)
            pending = [t for t in todo_titles if t not in done]
            print(f"ns{ns}: pending {len(pending)}", flush=True)
            for i in range(0, len(pending), 50):
                chunk = pending[i:i + 50]
                d = q(action="query", prop="revisions",
                      titles="|".join(chunk), rvprop="content|size",
                      rvslots="main")
                pages = {p["title"]: p for p in d["query"]["pages"].values()}
                for t in chunk:
                    pg = pages.get(t)
                    if pg is None or "revisions" not in pg:
                        print(f"  ? no revision: {t}", flush=True)
                        continue
                    rv = pg["revisions"][0]
                    c = rv["slots"]["main"]["*"]
                    rec = {"title": t, "ns": ns, "pageid": pg["pageid"],
                           "redirect": c.lstrip().startswith("#REDIRECT")
                           or c.lstrip().startswith("#redirect"),
                           "size": len(c), "content": c}
                    out_f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                    done[t] = rec
                print(f"  ns{ns}: {min(i + 50, len(pending))}/{len(pending)} "
                      f"(total {len(done)})", flush=True)
    print(f"TOTAL records: {len(done)}")
    # census
    by_ns = {}
    for r in done.values():
        by_ns.setdefault(r["ns"], [0, 0])
        by_ns[r["ns"]][0] += 1
        if r["redirect"]:
            by_ns[r["ns"]][1] += 1
    print("by ns (total, redirects):", {k: v for k, v in sorted(by_ns.items())})


if __name__ == "__main__":
    crawl()
