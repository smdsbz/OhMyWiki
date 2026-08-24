#!/usr/bin/env python3
"""Analyze navigation hierarchy of the wiki, BFS from 首页.

Graph edges:
  - [[...]] internal wikilinks (File/Category/SMW-annotation excluded)
  - {{...}} template transclusions (page -> 模板:Name)
  - [[文件:...]] image references (page -> 文件:Name)
  - SMW {{#ask:...}} queries written directly in page wikitext:
      resolved through the live Semantic MediaWiki API (action=ask),
      page -> every result page
  - [[分类:X]] membership (page -> 分类:X, and 分类:X -> members)

Outputs:
  hierarchy.json          title, ns, level, parent, outlinks
  hierarchy-summary.txt   human-readable report
  ask-cache.json          cached SMW query results
"""
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict, deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

OUT = Path(__file__).resolve().parent
PAGES_DIR = OUT / "pages"
MANIFEST_JSONL = OUT / "manifest.jsonl"
CACHE = OUT / "ask-cache.json"

API = "https://xenoblade2.cn/api.php"
UA = "rakuen-database-analysis/1.0"

LINK_RE = re.compile(r"\[\[([^\]\n]+?)\]\]")
TEMPLATE_RE = re.compile(r"\{\{([^{}\n]+?)\}\}")
ASK_RE = re.compile(r"\{\{#ask:\s*([^{}]+?)\}\}", re.S)
COND_RE = re.compile(r"\[\[[^\]]*\]\]")
SPACE_RE = re.compile(r"\s+")

STRIP_BLOCKS = [
    (r"<nowiki>.*?</nowiki>", re.S),
    (r"<syntaxhighlight.*?</syntaxhighlight>", re.S | re.I),
    (r"<source\s+.*?</source>", re.S | re.I),
    (r"<pre>.*?</pre>", re.S),
    (r"<code>.*?</code>", re.S | re.I),
]

EXCLUDED_TARGET_PREFIXES = ("File:", "Special:", "MediaWiki:", "Media:",
                            "Gadget:", "Gadget definition:", "特殊:", "媒体:",
                            "媒体文件:")


def norm_title(t: str) -> str:
    t = SPACE_RE.sub(" ", t.replace("_", " ")).strip()
    if t:
        t = t[0].upper() + t[1:]
    return t


def strip_code_blocks(text: str) -> str:
    for pat, flags in STRIP_BLOCKS:
        text = re.sub(pat, "", text, flags=flags)
    return text


def api(params: dict, retries: int = 5) -> dict:
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=300) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            print(f"  ! ask failed ({e}); retry {attempt}/{retries}", flush=True)
            time.sleep(2 * attempt)
    raise RuntimeError(f"giving up: {url}")


def resolve_ask(query_body: str) -> list:
    """query_body: the raw {{#ask: ...}} inner text. Returns matched titles."""
    conds = COND_RE.findall(query_body)
    if not conds:
        return []
    limit = 1000
    m = re.search(r"\|\s*limit\s*=\s*(\d+)", query_body)
    if m:
        limit = int(m.group(1))
    q = "".join(conds) + f"|limit={limit}"
    titles = []
    offset = 0
    while True:
        params = {"action": "ask", "query": q + f"|offset={offset}", "format": "json"}
        d = api(params)
        res = d.get("query", {}).get("results", {})
        batch = list(res.keys())
        titles.extend(batch)
        offset += len(batch)
        if not batch or len(batch) < limit:
            break
        time.sleep(0.1)
    return titles


def interpolate(q: str, title: str) -> str:
    ns = title.split(":", 1)[0] if ":" in title else ""
    rest = title.split(":", 1)[1] if ":" in title else title
    pagename = rest.split("/", 1)[0] if "/" in rest else rest
    sub = rest.rsplit("/", 1)[-1]
    q = q.replace("{{FULLPAGENAME}}", title)
    q = q.replace("{{PAGENAME}}", pagename)
    q = q.replace("{{SUBPAGENAME}}", sub)
    q = q.replace("{{NAMESPACE}}", ns)
    return q


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    print("== loading manifest ==", flush=True)
    pages = []
    for line in MANIFEST_JSONL.read_text(encoding="utf-8").splitlines():
        if line.strip():
            pages.append(json.loads(line))
    title_to_idx = {p["title"]: i for i, p in enumerate(pages)}
    print(f"  {len(pages)} pages", flush=True)

    print("== parsing wikitext ==", flush=True)
    outlinks = [set() for _ in pages]
    category_members = defaultdict(set)
    ask_requests = []          # (page_idx, unique_query_key, query_body)
    stats = Counter()

    for i, p in enumerate(pages):
        path = PAGES_DIR / p["path"]
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        text = strip_code_blocks(text)
        title = p["title"]
        base = title.rsplit("/", 1)[0]

        for raw in LINK_RE.findall(text):
            if raw.startswith(("[", "{", "'", '"')):
                continue
            target = raw.split("|", 1)[0].split("#", 1)[0].strip()
            if not target or "{" in target or "::" in target:
                continue
            if target.startswith("/") and base:
                target = base + target
            elif target.startswith("./"):
                target = (base + target[1:]) if base else target[2:]
            target = norm_title(target)
            if target == title:
                continue
            if target.startswith(("File:", "文件:")):
                j = title_to_idx.get(target)
                if j is not None:
                    outlinks[i].add(j)
                    stats["file_ref"] += 1
                continue
            if target.startswith(("Category:", "分类:")):
                j = title_to_idx.get(target)
                if j is not None:
                    outlinks[i].add(j)
                    category_members[j].add(i)
                    stats["category_link"] += 1
                continue
            if target.startswith(EXCLUDED_TARGET_PREFIXES):
                stats["other_excluded"] += 1
                continue
            j = title_to_idx.get(target)
            if j is None:
                stats["red"] += 1
                continue
            outlinks[i].add(j)
            stats["wikilink"] += 1

        for raw in TEMPLATE_RE.findall(text):
            if raw.startswith("#"):
                continue
            name = raw.split("|", 1)[0].strip()
            if (not name or name.startswith(("#", ":", "="))
                    or ":" in name or "{" in name or "=" in name):
                continue
            j = title_to_idx.get("模板:" + norm_title(name))
            if j is not None:
                outlinks[i].add(j)
                stats["template"] += 1

        for q in ASK_RE.findall(text):
            if "format=count" in q or "|format=count" in q:
                stats["ask_count"] += 1
                continue
            q = interpolate(q, title)
            conds = COND_RE.findall(q)
            if not conds:
                continue
            key = "".join(conds)
            ask_requests.append((i, key, q))
            stats["ask"] += 1

    for cat, members in category_members.items():
        for m in members:
            outlinks[cat].add(m)

    print("  " + "; ".join(f"{k}: {v}" for k, v in stats.items()), flush=True)

    print("== resolving SMW queries via action=ask ==", flush=True)
    cache = {}
    if CACHE.exists():
        cache = json.loads(CACHE.read_text(encoding="utf-8"))
        print(f"  loaded {len(cache)} cached queries", flush=True)
    todo = []
    for idx, key, body in ask_requests:
        if key not in cache:
            todo.append((idx, key, body))
    unique = {k for _, k, _ in todo}
    print(f"  {len(ask_requests)} ask usages, {len(unique)} unique queries",
          flush=True)
    done = 0
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(resolve_ask, body): key for _, key, body in todo}
        for fut in as_completed(futs):
            key = futs[fut]
            try:
                cache[key] = fut.result()
            except Exception as e:
                print(f"  ! query failed: {e}", flush=True)
                cache[key] = []
            done += 1
            if done % 25 == 0:
                print(f"  {done}/{len(todo)} queries...", flush=True)
    with open(CACHE, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False)
    for idx, key, body in ask_requests:
        for t in cache.get(key, []):
            j = title_to_idx.get(t)
            if j is not None:
                outlinks[idx].add(j)
    print(f"  edges added from queries", flush=True)

    print("== BFS from 首页 ==", flush=True)
    start = title_to_idx.get("首页")
    level = [-1] * len(pages)
    parent = [-1] * len(pages)
    level[start] = 0
    q = deque([start])
    while q:
        u = q.popleft()
        for v in outlinks[u]:
            if level[v] == -1:
                level[v] = level[u] + 1
                parent[v] = u
                q.append(v)

    reachable = [i for i, lv in enumerate(level) if lv != -1]
    unreachable = [i for i, lv in enumerate(level) if lv == -1]
    print(f"  reachable: {len(reachable)} ({len(reachable) / len(pages) * 100:.1f}%)"
          f"   unreachable: {len(unreachable)}", flush=True)

    def ns_dist(indices):
        c = Counter(pages[i]["ns"] for i in indices)
        return {k: c[k] for k in sorted(c, key=lambda x: -c[x])}

    dist = Counter(level[i] for i in reachable)
    lines = []
    lines.append("== level distribution (distance from 首页) ==")
    lines.append(f"  {'level':<6}{'pages':>8}{'cum%':>8}")
    cum = 0
    for lv in sorted(dist):
        cum += dist[lv]
        lines.append(f"  {lv:<6}{dist[lv]:>8}{cum / len(pages) * 100:>7.1f}%")
    lines.append("")
    lines.append("== unreachable pages by namespace ==")
    for ns, c in ns_dist(unreachable).items():
        lines.append(f"  ns {ns}: {c}")
    lines.append("")
    lines.append("== level-1 pages (directly from 首页) ==")
    for t in sorted(pages[i]["title"] for i in reachable if level[i] == 1):
        lines.append(f"  {t}")
    lines.append("")
    lines.append("== sample level-2 pages ==")
    for t in sorted(pages[i]["title"] for i in reachable if level[i] == 2)[:40]:
        lines.append(f"  {t}")
    lines.append("")
    lines.append(f"  max depth: {max(dist)} hops")

    report = "\n".join(lines) + "\n"
    print(report)
    (OUT / "hierarchy-summary.txt").write_text(report, encoding="utf-8")

    print("== saving hierarchy.json ==", flush=True)
    result = []
    for i, p in enumerate(pages):
        result.append({
            "title": p["title"],
            "ns": p["ns"],
            "level": level[i],
            "parent": pages[parent[i]]["title"] if parent[i] != -1 else None,
            "outlinks": len(outlinks[i]),
        })
    with open(OUT / "hierarchy.json", "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)
    print("  saved", flush=True)


if __name__ == "__main__":
    main()
