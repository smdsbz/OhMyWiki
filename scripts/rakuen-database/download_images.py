#!/usr/bin/env python3
"""Download all image files from xenoblade2.cn (resumable, parallel).

Usage: python download_images.py [workers]     (default 8)

Layout:
  images/<filename>          original image files
  images-manifest.jsonl      name -> local path / size / mime
  images-summary.json        run summary (pending / failed)
Resume: files already on disk with the expected size are skipped.
"""
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

OUT = Path(__file__).resolve().parent
IMAGES_DIR = OUT / "images"
MANIFEST_JSONL = OUT / "images-manifest.jsonl"
SUMMARY_JSON = OUT / "images-summary.json"

API = "https://xenoblade2.cn/api.php"
UA = "rakuen-database-images/1.0 (image download)"
REFERER = "https://xenoblade2.cn/"

ILLEGAL_FS = re.compile(r'[<>:"\\|?*]')


def api(params: dict, retries: int = 5) -> dict:
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": UA, "Referer": REFERER,
                              "Accept-Encoding": "identity"})
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = resp.read()
            try:
                return json.loads(raw.decode("utf-8"))
            except UnicodeDecodeError:
                import gzip
                return json.loads(gzip.decompress(raw).decode("utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            print(f"  ! api failed ({e}); retry {attempt}/{retries}", flush=True)
            time.sleep(2 * attempt)
    raise RuntimeError(f"giving up: {url}")


def list_all_images() -> list:
    items = []
    aicontinue = None
    while True:
        p = {"action": "query", "list": "allimages", "ailimit": "500",
             "aiprop": "url|size|mime", "format": "json"}
        if aicontinue:
            p["aicontinue"] = aicontinue
        d = api(p)
        items.extend(d["query"]["allimages"])
        cont = d.get("continue", {})
        if "aicontinue" in cont:
            aicontinue = cont["aicontinue"]
        else:
            break
        print(f"  listed {len(items)} files...", flush=True)
    return items


def safe_name(name: str) -> str:
    name = ILLEGAL_FS.sub("_", name)
    if len(name) > 200:
        name = name[:200]
    return name


def download_one(item: dict, retries: int = 6) -> tuple:
    """Range-resume download: partial bytes live in <name>.part so stalled
    connections continue where they left off instead of restarting."""
    name = item["name"]
    size = item["size"]
    local = IMAGES_DIR / safe_name(name)
    if local.exists() and local.stat().st_size == size:
        return "skip", name, local
    part = local.with_suffix(local.suffix + ".part")
    have = part.stat().st_size if part.exists() else 0
    if have > size:
        part.unlink()
        have = 0
    if have == size:
        part.replace(local)
        return "ok", name, local
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            headers = {"User-Agent": UA, "Referer": REFERER}
            if have:
                headers["Range"] = f"bytes={have}-"
            req = urllib.request.Request(item["url"], headers=headers)
            with urllib.request.urlopen(req, timeout=240) as resp:
                if resp.status == 200 and have:
                    part.write_bytes(b"")
                    have = 0
                with open(part, "ab") as f:
                    while True:
                        chunk = resp.read(65536)
                        if not chunk:
                            break
                        f.write(chunk)
                        have += len(chunk)
                if have < size:
                    raise OSError(f"short read: {have}/{size}")
            part.replace(local)
            return "ok", name, local
        except Exception as e:
            last_err = e
            if attempt < retries:
                print(f"  ! {name} at {have}/{size} ({e}); "
                      f"retry {attempt}/{retries}", flush=True)
                time.sleep(min(2 ** attempt, 30))
    print(f"  !! {name} deferred this round ({last_err})", flush=True)
    return "part", name, local


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    workers = max(1, int(sys.argv[1])) if len(sys.argv) > 1 else 2
    until_done = "--until-done" in sys.argv
    start = time.time()

    while True:
        print("== listing all images ==", flush=True)
        items = list_all_images()
        print(f"  {len(items)} files total", flush=True)
        IMAGES_DIR.mkdir(exist_ok=True)

        done = set()
        if MANIFEST_JSONL.exists():
            for line in MANIFEST_JSONL.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    done.add(json.loads(line)["name"])

        todo = [it for it in items if it["name"] not in done]
        print(f"  checkpoint: {len(done)} done, {len(todo)} to download",
              flush=True)
        if not todo:
            break

        errors = []
        n_ok = n_skip = n_part = 0
        print(f"== downloading ({workers} workers) ==", flush=True)
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futs = {ex.submit(download_one, it): it for it in todo}
            for fut in as_completed(futs):
                it = futs[fut]
                try:
                    status, name, local = fut.result()
                except Exception as e:
                    print(f"  ! failed: {it['name']} ({e})", flush=True)
                    errors.append([it["name"], str(e)])
                    continue
                if status == "ok":
                    n_ok += 1
                    entry = {"name": name, "path": local.relative_to(OUT).as_posix(),
                             "bytes": local.stat().st_size,
                             "size": it["size"], "mime": it["mime"],
                             "url": it["url"]}
                    with open(MANIFEST_JSONL, "a", encoding="utf-8") as f:
                        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
                elif status == "part":
                    n_part += 1
                else:
                    n_skip += 1
                if (n_ok + n_skip + n_part + len(errors)) % 250 == 0:
                    print(f"  {n_ok + n_skip + n_part + len(errors)}/{len(todo)}...",
                          flush=True)

        cur = set()
        for line in MANIFEST_JSONL.read_text(encoding="utf-8").splitlines():
            if line.strip():
                cur.add(json.loads(line)["name"])
        pending = [it["name"] for it in todo
                   if it["name"] not in cur
                   and it["name"] not in {e[0] for e in errors}]
        print(f"  run: {n_ok} downloaded, {n_skip} present, "
              f"{n_part} partial (will resume), {len(errors)} failed, "
              f"{len(pending)} pending", flush=True)
        if not until_done or not pending:
            break
        print(f"  {len(pending)} still pending; retrying in 15s "
              f"(Ctrl-C to stop)", flush=True)
        time.sleep(15)

    summary = {
        "exported_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "total_files": len(items),
        "failed": [e for e in errors] if "errors" in dir() else [],
        "pending": pending if "pending" in dir() else [],
        "elapsed_seconds": round(time.time() - start, 1),
    }
    with open(SUMMARY_JSON, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    print(f"== finished in {summary['elapsed_seconds']}s; pending: "
          f"{len(summary['pending'])} ==", flush=True)


if __name__ == "__main__":
    main()
