#!/usr/bin/env python3
"""Full parallel dump of all pages from xenoblade2.cn MediaWiki, resumable.

Usage:
  python export_wiki.py [workers]              # default workers=8
  python export_wiki.py 8 --until-done         # keep retrying until ALL pages are downloaded
  python export_wiki.py 8 --rescan             # force re-run phase 1 (page listing)
  python export_wiki.py 8 --batch 25           # pages per API request (default 25)

Layout:
  pages/<namespace>/<title path>/.../<title>.wiki   one file per page (raw wikitext)
  titles.txt            all page titles
  manifest.jsonl        one JSON entry per exported page (append-only, resumable)
  manifest.json         consolidated manifest (rewritten at end of each run)
  checkpoint.txt        completed pageids (append-only, resumable)
  pages.jsonl           page list from phase 1 (skip phase 1 on resume)
  summary.json          run metadata / pending pages

Only pages that were successfully fetched AND written are marked done in the
checkpoint, so failed or interrupted batches are always retried on the next
run until every single page is downloaded.
"""
import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

API = "https://xenoblade2.cn/api.php"
UA = "rakuen-database-export/1.0 (full MediaWiki page dump via API)"
OUT = Path(__file__).resolve().parent
PAGES_DIR = OUT / "pages"
CHECKPOINT = OUT / "checkpoint.txt"
MANIFEST_JSONL = OUT / "manifest.jsonl"
MANIFEST_JSON = OUT / "manifest.json"
PAGES_JSONL = OUT / "pages.jsonl"
TITLES_TXT = OUT / "titles.txt"
SUMMARY_JSON = OUT / "summary.json"

ILLEGAL_XML = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")
ILLEGAL_FS = re.compile(r'[<>:"\\|?*]')
RESERVED = {"CON", "PRN", "AUX", "NUL"} | {f"COM{i}" for i in range(1, 10)} | {f"LPT{i}" for i in range(1, 10)}


def api(params: dict, retries: int = 5) -> dict:
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=300) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            print(f"  ! request failed ({e}); retry {attempt}/{retries}", flush=True)
            time.sleep(3 * attempt)
    raise RuntimeError(f"giving up after {retries} attempts: {url}")


def get_siteinfo():
    d = api({"action": "query", "meta": "siteinfo",
             "siprop": "general|namespaces", "format": "json"})
    query = d["query"]
    ns_ids = [int(k) for k in query["namespaces"] if int(k) >= 0]
    return query["general"], query["namespaces"], ns_ids


def collect_ns(ns: int) -> list:
    pages = []
    apcontinue = None
    while True:
        p = {"action": "query", "list": "allpages", "aplimit": "500",
             "apnamespace": str(ns), "format": "json"}
        if apcontinue:
            p["apcontinue"] = apcontinue
        d = api(p)
        pages.extend(d["query"]["allpages"])
        cont = d.get("continue", {})
        if "apcontinue" in cont:
            apcontinue = cont["apcontinue"]
        else:
            return pages


def load_pages():
    if not PAGES_JSONL.exists():
        return None
    pages = []
    for line in PAGES_JSONL.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        obj = json.loads(line)
        if obj.get("_done"):
            return pages
        pages.append(obj)
    return None


def collect_titles(ns_ids, workers, max_attempts=4):
    pages = []
    remaining = list(ns_ids)
    for attempt in range(1, max_attempts + 1):
        if not remaining:
            break
        failed = []
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futs = {ex.submit(collect_ns, ns): ns for ns in remaining}
            for fut in as_completed(futs):
                ns = futs[fut]
                try:
                    batch = fut.result()
                    pages.extend(batch)
                    print(f"  namespace {ns}: {len(batch)} pages ({len(pages)} total)",
                          flush=True)
                except Exception as e:
                    print(f"  ! namespace {ns} failed: {e} "
                          f"(attempt {attempt}/{max_attempts})", flush=True)
                    failed.append(ns)
        remaining = failed
        if failed:
            print(f"  retrying {len(failed)} failed namespaces...", flush=True)
            time.sleep(3)
    incomplete = bool(remaining)
    if incomplete:
        print(f"  WARNING: {len(remaining)} namespaces still failing: {remaining}",
              flush=True)
        print("  pages.jsonl written without completion marker; "
              "a later run will re-collect them", flush=True)
    pages.sort(key=lambda p: (p["ns"], p["title"]))
    with open(PAGES_JSONL, "w", encoding="utf-8") as f:
        for p in pages:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
        if not incomplete:
            f.write(json.dumps({"_done": True}) + "\n")
    return pages


def load_checkpoint():
    done = set()
    if CHECKPOINT.exists():
        for line in CHECKPOINT.read_text(encoding="utf-8").splitlines():
            for pid in line.split():
                done.add(int(pid))
    manifest = []
    if MANIFEST_JSONL.exists():
        for line in MANIFEST_JSONL.read_text(encoding="utf-8").splitlines():
            if line.strip():
                manifest.append(json.loads(line))
    return done, manifest


def fetch_batch(pageids: list) -> list:
    p = {"action": "query", "pageids": "|".join(map(str, pageids)),
         "prop": "revisions", "rvprop": "content",
         "format": "json"}
    d = api(p)
    if "error" in d:
        raise RuntimeError(d["error"])
    return list(d.get("query", {}).get("pages", {}).values())


def sanitize_component(name: str) -> str:
    name = ILLEGAL_FS.sub("_", name).rstrip(" .")
    if not name or name.upper() in RESERVED:
        name = "_" + name
    return name


def assign_path(info, ns_names):
    ns = int(info["ns"])
    title = info["title"]
    if ns == 0:
        ns_dir = "Main"
    else:
        ns_name = ns_names.get(ns, {})
        local = ns_name.get("*") or ns_name.get("canonical") or str(ns)
        ns_dir = sanitize_component(local)
    if ns != 0 and ":" in title:
        title = title.split(":", 1)[1]
    parts = [sanitize_component(seg) for seg in title.split("/")]
    parts[-1] += ".wiki"
    return Path(ns_dir, *parts)


def write_one(content, rel: Path) -> int:
    content = ILLEGAL_XML.sub("", content)
    target = PAGES_DIR / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    with open(target, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)
    return target.stat().st_size


def worker(pageids, by_id, rel_paths, errors):
    batch = fetch_batch(pageids)
    fetched = {}
    for page in batch:
        fetched[page["pageid"]] = page
    entries = []
    for pid in pageids:
        info = by_id[pid]
        rel = rel_paths[pid]
        page = fetched.get(pid)
        content = ""
        if page:
            rev = (page.get("revisions") or [None])[0]
            if rev:
                if "*" in rev:
                    content = rev["*"]
                else:
                    content = ((rev.get("slots") or {}).get("main") or {}).get("*") or ""
        try:
            size = write_one(content, rel)
            entries.append({"title": info["title"], "ns": info["ns"],
                            "pageid": pid, "path": rel.as_posix(), "bytes": size})
        except OSError as e:
            errors.append([info["title"], str(e)])
    return entries


def fetch_raw(title: str) -> str:
    url = "https://xenoblade2.cn/index.php?" + urllib.parse.urlencode(
        {"title": title, "action": "raw"})
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=600) as resp:
        return resp.read().decode("utf-8")


def phase3(pending_ids, workers, batch_size, by_id, rel_paths, manifest, done,
           max_rounds=4):
    errors = []
    round_no = 1
    while pending_ids and round_no <= max_rounds:
        print(f"== phase 3 (round {round_no}/{max_rounds}): "
              f"fetching {len(pending_ids)} pages ==", flush=True)
        batches = [pending_ids[i:i + batch_size]
                   for i in range(0, len(pending_ids), batch_size)]
        failed = []
        finished = 0
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futs = {ex.submit(worker, b, by_id, rel_paths, errors): b
                    for b in batches}
            for fut in as_completed(futs):
                batch_ids = futs[fut]
                try:
                    entries = fut.result()
                except Exception as e:
                    print(f"  ! batch failed: {e} (round {round_no}, "
                          f"{len(batch_ids)} pages, retried later)", flush=True)
                    failed.extend(batch_ids)
                    continue
                manifest.extend(entries)
                with open(MANIFEST_JSONL, "a", encoding="utf-8") as f:
                    for e in entries:
                        f.write(json.dumps(e, ensure_ascii=False) + "\n")
                with open(CHECKPOINT, "a", encoding="utf-8") as f:
                    for e in entries:
                        f.write(str(e["pageid"]) + "\n")
                done.update(e["pageid"] for e in entries)
                finished += 1
                if finished % 50 == 0:
                    print(f"  {finished}/{len(batches)} batches "
                          f"({len(manifest)} pages)...", flush=True)
        pending_ids = failed
        round_no += 1
        if pending_ids and round_no <= max_rounds:
            print(f"  {len(pending_ids)} pages still pending; retrying...",
                  flush=True)
            time.sleep(5)

    if pending_ids:
        print(f"== phase 3 (raw fallback): fetching {len(pending_ids)} pages "
              f"one by one via action=raw ==", flush=True)
        still_pending = []
        for pid in pending_ids:
            info = by_id[pid]
            try:
                content = fetch_raw(info["title"])
            except Exception as e:
                print(f"  ! raw fallback failed for {info['title']}: {e} "
                      f"(retried next run)", flush=True)
                still_pending.append(pid)
                continue
            size = write_one(content, rel_paths[pid])
            entry = {"title": info["title"], "ns": info["ns"],
                     "pageid": pid, "path": rel_paths[pid].as_posix(),
                     "bytes": size, "via": "raw"}
            manifest.append(entry)
            with open(MANIFEST_JSONL, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")
            with open(CHECKPOINT, "a", encoding="utf-8") as f:
                f.write(str(pid) + "\n")
            done.add(pid)
        pending_ids = still_pending
    return manifest, pending_ids, errors


def run_once(workers, batch_size, rescan):
    start = time.time()
    print("== fetching siteinfo ==", flush=True)
    general, namespaces, ns_ids = get_siteinfo()
    ns_names = {int(k): v for k, v in namespaces.items()}
    print(f"  {general['sitename']} (db: {general['wikiid']}), generator: "
          f"{general['generator']}, {len(ns_ids)} namespaces, "
          f"concurrency: {workers}, batch: {batch_size}", flush=True)

    pages = None if rescan else load_pages()
    if pages is None:
        print("== phase 1: collecting all page titles ==", flush=True)
        collect_titles(ns_ids, min(workers, 6))
        pages = load_pages()
    else:
        print(f"== phase 1: loaded {len(pages)} pages from pages.jsonl "
              f"(use --rescan to refresh) ==", flush=True)
    if pages is None:
        print("!! phase 1 could not complete; try again later", flush=True)
        return None
    with open(TITLES_TXT, "w", encoding="utf-8", newline="\n") as f:
        for p in pages:
            f.write(p["title"] + "\n")
    by_id = {p["pageid"]: p for p in pages}

    done, manifest = load_checkpoint()
    pending_ids = [p["pageid"] for p in pages if p["pageid"] not in done]
    print(f"== checkpoint: {len(done)} pages done, {len(pending_ids)} pending ==",
          flush=True)

    print("== phase 2: assigning paths ==", flush=True)
    rel_paths = {}
    used = set()
    for p in pages:
        rel = assign_path(p, ns_names)
        while rel.as_posix() in used:
            rel = rel.with_name(rel.stem + "_dup" + rel.suffix)
        used.add(rel.as_posix())
        rel_paths[p["pageid"]] = rel

    if pending_ids:
        manifest, pending_ids, errors = phase3(
            pending_ids, workers, batch_size, by_id, rel_paths, manifest, done)
        if errors:
            print(f"  {len(errors)} write errors (see summary.json)", flush=True)
        print(f"  done: {len(manifest)} files written", flush=True)
    else:
        print("== nothing pending, all pages already exported ==", flush=True)

    with open(MANIFEST_JSON, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    missing = [p for p in pages if p["pageid"] not in done]
    summary = {
        "site": general["sitename"],
        "dbname": general["wikiid"],
        "url": general["server"] + general["articlepath"].replace("$1", ""),
        "exported_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "total_pages": len(pages),
        "exported_files": len(manifest),
        "pending_pages": [p["title"] for p in missing],
        "elapsed_seconds": round(time.time() - start, 1),
    }
    with open(SUMMARY_JSON, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    return len(missing)


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description="Resumable full dump of xenoblade2.cn")
    ap.add_argument("workers", nargs="?", type=int, default=8)
    ap.add_argument("--rescan", action="store_true",
                    help="force re-running phase 1 (page listing)")
    ap.add_argument("--until-done", action="store_true",
                    help="keep retrying until every page is downloaded")
    ap.add_argument("--batch", type=int, default=25,
                    help="pages per API request (default 25)")
    args = ap.parse_args()
    workers = max(1, args.workers)
    batch_size = max(1, min(args.batch, 50))

    pending = run_once(workers, batch_size, args.rescan)
    while args.until_done and pending is not None and pending > 0:
        print(f"\n!! {pending} pages still pending; "
              f"retrying in 15s (Ctrl-C to stop) ==", flush=True)
        time.sleep(15)
        pending = run_once(workers, batch_size, args.rescan)

    if pending is None:
        print("== run ended with phase 1 incomplete; rerun to continue ==",
              flush=True)
    elif pending == 0:
        print("== ALL PAGES DOWNLOADED ==", flush=True)
    else:
        print(f"== run finished; {pending} pages still pending — "
              f"rerun to continue (or use --until-done) ==", flush=True)


if __name__ == "__main__":
    main()
