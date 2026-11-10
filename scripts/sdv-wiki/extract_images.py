# Extract all images from the Kiwix ZIM into out/sdv-images/ (flat, decoded names).
# ZIM v6 (libzim9): see zim-probe.mjs verification. Python 3.14 compression.zstd.
import json
import struct
import sys
import urllib.parse
import zlib
from pathlib import Path

from compression import zstd

ZIM = Path(r"C:\Users\69406\Documents\Projects\stardewvalleywiki_en_all_2026-10.zim")
OUT = Path(__file__).parent / "out"
IMGDIR = OUT / "sdv-images"
IMGDIR.mkdir(parents=True, exist_ok=True)

buf = ZIM.read_bytes()

article_count = struct.unpack_from("<I", buf, 24)[0]
url_ptr_pos = struct.unpack_from("<q", buf, 32)[0]
cluster_ptr_pos = struct.unpack_from("<q", buf, 48)[0]
mime_list_pos = struct.unpack_from("<q", buf, 56)[0]

# mime list
mimes = []
p = mime_list_pos
while True:
    e = buf.index(b"\x00", p)
    s = buf[p:e].decode("utf-8", "replace")
    if not s:
        break
    mimes.append(s)
    p = e + 1
IMG_MIME_IDX = {i for i, m in enumerate(mimes) if m.startswith("image/")}
print(f"articles={article_count} image mimes: "
      f"{[mimes[i] for i in sorted(IMG_MIME_IDX)]}")

clusters = {}  # ci -> decompressed bytes


def cluster_data(ci: int) -> bytes:
    if ci in clusters:
        return clusters[ci]
    off = struct.unpack_from("<q", buf, cluster_ptr_pos + ci * 8)[0]
    comp = buf[off] & 0x0F
    raw = bytes(buf[off + 1:])
    if comp in (0, 1):  # 0x01 clusters verified raw in this file (PNG magic)
        data = raw
    elif comp == 5:
        d = zstd.ZstdDecompressor()
        try:
            data = d.decompress(raw)
        except zstd.ZstdError:
            dobj = d.decompressobj()
            data = dobj.decompress(raw) + dobj.flush()
    else:
        raise RuntimeError(f"cluster {ci} compression {comp} unsupported")
    if len(clusters) > 8:
        clusters.pop(next(iter(clusters)))
    clusters[ci] = data
    return data


def cstr(pos: int) -> str:
    e = buf.index(b"\x00", pos)
    return buf[pos:e].decode("utf-8", "replace")


stats = {"images": 0, "skipped_redirect": 0, "bad_name": 0}
manifest = []
for i in range(article_count):
    off = struct.unpack_from("<q", buf, url_ptr_pos + i * 8)[0]
    mt = struct.unpack_from("<H", buf, off)[0]
    if mt == 0xFFFF:
        continue
    if mt not in IMG_MIME_IDX:
        continue
    ci = struct.unpack_from("<i", buf, off + 8)[0]
    bi = struct.unpack_from("<i", buf, off + 12)[0]
    url = cstr(off + 16)
    name_enc = url.split("/")[-1]
    name = urllib.parse.unquote(name_enc)
    # windows-illegal chars -> '_' (packaging rule); engine probe adds same variant
    safe = name
    for ch in '<>:"\\|?*':
        safe = safe.replace(ch, "_")
    try:
        data = cluster_data(ci)
        a = struct.unpack_from("<I", data, bi * 4)[0]
        b = struct.unpack_from("<I", data, (bi + 1) * 4)[0]
        blob = data[a:b]
    except Exception as e:
        print(f"  ! blob fail {url}: {e}")
        stats["bad_name"] += 1
        continue
    dest = IMGDIR / safe
    if not dest.exists() or dest.stat().st_size != len(blob):
        dest.write_bytes(blob)
    stats["images"] += 1
    manifest.append({"zim_url": url, "name": name, "file": safe,
                     "bytes": len(blob), "mime": mimes[mt]})
    if stats["images"] % 1000 == 0:
        print(f"  ...{stats['images']}", flush=True)

(OUT / "sdv-images-manifest.json").write_text(
    json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
changed = sum(1 for m in manifest if m["name"] != m["file"])
print(f"extracted {stats['images']} images -> {IMGDIR}")
print(f"names sanitized (illegal chars): {changed}")
exts = {}
for m in manifest:
    ext = m["file"].rsplit(".", 1)[-1].lower() if "." in m["file"] else "(none)"
    exts[ext] = exts.get(ext, 0) + 1
print("by ext:", exts)
print(f"total bytes: {sum(m['bytes'] for m in manifest)/1e6:.1f} MB")
