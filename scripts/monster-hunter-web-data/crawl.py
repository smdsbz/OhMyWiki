#!/usr/bin/env python3
"""Crawl angrychocobo.github.io/monster-hunter-web-data (MHXX 攻略大全 static site)
into a local wiki site dump for the OhMyWiki reader.

Output layout (this folder, same conventions as rakuen-database):
  pages/<ns>/<title>.wiki   converted wikitext (one file per page)
  images/<flat-name>        downloaded images (subdirs flattened with '-')
  manifest.json             [{title, ns, pageid, path, bytes}]
  summary.json              site metadata
  cache/                    raw HTML cache (incremental; delete to re-fetch)

Usage:
  python crawl.py                 # full crawl + convert + images
  python crawl.py --convert-only  # re-convert from cache (no network)
  python crawl.py --limit 50      # crawl at most N pages (converter smoke test)
  python crawl.py --no-images     # skip image download

Site knowledge (classes/ids/colors/URL shapes) lives HERE, not in the app.
Color values verified against index.css on 2026-09-14.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
from html.parser import HTMLParser
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

SITE = "https://angrychocobo.github.io/monster-hunter-web-data/"
BASE_PATH = urllib.parse.urlsplit(SITE).path  # "/monster-hunter-web-data/"
UA = "OhMyWiki-dump/1.0 (offline mirror of monster-hunter-web-data)"

OUT = Path(__file__).resolve().parent
CACHE = OUT / "cache"
PAGES = OUT / "pages"
IMAGES = OUT / "images"

# ---- site knowledge: class -> color (index.css, verified 2026-09-14) ----
CLASS_COLORS = {
    "c_g": "#008000", "gb": "#008000", "c_gb": "#008000",
    "c_p": "#9c27b0", "rp": "#9c27b0",
    "c_r": "#ff0000", "rb": "#ff0000",
    "c_b": "#666666", "c_bb": "#666666",
    "c_o": "#ffa500", "c_ob": "#ffa500",
    # 斩位条 kr0..kr7；kr5 原站白色（衬 #ccc 单元格底），白底文档不可见 → 浅灰
    "kr0": "#bc0b43", "kr1": "#f45600", "kr2": "#ffc836", "kr3": "#4de200",
    "kr4": "#4068fa", "kr5": "#d0d0d0", "kr6": "#cc33cc", "kr7": "#555555",
}
BOLD_CLASSES = {"b", "c_gb", "c_ob"}
SKIP_TAGS = {"script", "style", "noscript", "head", "meta", "link", "title",
             "input", "select", "option", "iframe", "ins", "form", "button"}
# 站点交互控件说明框（全开/全闭按钮，离线无意义）
SKIP_CLASSES = {"box1", "box2"}
# 超过该行数的表格按 sub_th 分隔行拆分为子页面（如武器派生 ~600 行 eager 渲染会卡死主线程）
SPLIT_TABLE_MIN_ROWS = 80
# 无结构边界的大表按行切块（道具用途/技能页）；含 rowspan 的表不切块（防跨块截断）
CHUNK_TABLE_ROWS = 80
# 超大单元格（如道具[用途]格内数百条 <br> 条目，单段千级 Span 会卡布局）按条目切多行
CELL_SPLIT_CHARS = 4000
CELL_SPLIT_ITEMS = 40
# 超大页面按 ==标题== 切子页面（如防具稀有度页：77 个 panel 标题 + 小表）
PAGE_SPLIT_MIN_CHARS = 100_000
PAGE_SPLIT_MIN_SECTIONS = 2
# 拆分后单节仍超大（如道具[用途]上千条目）→ 按条目再切块
SECTION_MAX_CHARS = 80_000
SECTION_CHUNK_ITEMS = 150

ILLEGAL_FS = re.compile(r'[<>:"\\|?*\x00-\x1f]')
RESERVED = {"CON", "PRN", "AUX", "NUL"} | {f"COM{i}" for i in range(1, 10)} | {f"LPT{i}" for i in range(1, 10)}


def fs_safe(name: str) -> str:
    name = ILLEGAL_FS.sub("_", name).strip().rstrip(". ")
    if not name:
        name = "_"
    if name.upper() in RESERVED:
        name += "_"
    return name


# ---------------------------------------------------------------- fetch ----
def fetch(url: str, retries: int = 4) -> bytes | None:
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read()
        except OSError as e:
            code = getattr(e, "code", None)
            if code == 404:
                return None
            print(f"  ! fetch fail {url} ({e}) retry {attempt}/{retries}", flush=True)
            time.sleep(2 * attempt)
    return None


HREF_RE = re.compile(r'href="([^"]+)"')


def normalize_link(base_rel: str, href: str) -> str | None:
    """Resolve href against the page's site-relative path -> site-relative
    path of an internal page, or None for external/other targets."""
    if href.startswith(("http://", "https://", "mailto:", "javascript:", "#")):
        return None
    abs_url = urllib.parse.urljoin(SITE + base_rel, href)
    if not abs_url.startswith(SITE):
        return None
    rel = urllib.parse.unquote(urllib.parse.urlsplit(abs_url).path)
    if not rel.startswith(BASE_PATH):
        return None
    rel = rel[len(BASE_PATH):]
    if rel == "" or rel.endswith("/"):
        rel += "index.html"
    if not re.fullmatch(r"(index\.html|(data|ida)/\d+\.html)", rel):
        return None
    return rel


def crawl(limit: int | None) -> list[str]:
    CACHE.mkdir(exist_ok=True)
    for d in ("data", "ida"):
        (CACHE / d).mkdir(exist_ok=True)
    seen: set[str] = {"index.html"}
    queue: list[str] = ["index.html"]
    failed: list[str] = []
    count = 0

    def harvest(rel: str, text: str) -> None:
        nonlocal count
        cp = CACHE / rel
        if not cp.exists():
            cp.write_text(text, encoding="utf-8")
        count += 1
        if count % 100 == 0:
            print(f"  processed {count} pages (seen {len(seen)})", flush=True)
        for href in HREF_RE.findall(text):
            nxt = normalize_link(rel, href)
            if nxt and nxt not in seen:
                seen.add(nxt)  # 入队即标记，防止导航链接在海量页面间重复入队
                queue.append(nxt)

    while queue:
        batch: list[str] = []
        while queue and len(batch) < 24:
            rel = queue.pop(0)
            batch.append(rel)
        if not batch:
            break
        # 已缓存的页面直接读盘（断点续爬），只下载缺失页
        to_fetch: list[str] = []
        for rel in batch:
            cp = CACHE / rel
            if cp.exists():
                harvest(rel, cp.read_text(encoding="utf-8"))
                if limit is not None and count >= limit:
                    return sorted(r for r in seen if (CACHE / r).exists())
            else:
                to_fetch.append(rel)
        if not to_fetch:
            continue
        with ThreadPoolExecutor(max_workers=16) as pool:
            futs = {pool.submit(fetch, SITE + rel): rel for rel in to_fetch}
            for fut in as_completed(futs):
                rel = futs[fut]
                data = fut.result()
                if data is None:
                    failed.append(rel)
                    continue
                harvest(rel, data.decode("utf-8", errors="replace"))
                if limit is not None and count >= limit:
                    print(f"  --limit {limit} reached, stop crawling", flush=True)
                    return sorted(r for r in seen if (CACHE / r).exists())
    if failed:
        print(f"  ! failed pages ({len(failed)}): {failed[:10]}...", flush=True)
    return sorted(r for r in seen if (CACHE / r).exists())


# ------------------------------------------------------------- mini DOM ----
VOID_TAGS = {"img", "br", "hr", "input", "meta", "link", "area", "base", "col",
             "embed", "source", "track", "wbr"}


class El:
    __slots__ = ("tag", "attrs", "children")

    def __init__(self, tag: str, attrs: dict):
        self.tag = tag
        self.attrs = attrs
        self.children: list = []

    def cls(self) -> list:
        return (self.attrs.get("class") or "").split()

    def attr(self, name: str) -> str | None:
        return self.attrs.get(name)


class DomBuilder(HTMLParser):
    """Very small forgiving tree builder (pages are server-rendered and
    mostly well-formed; <li>/<p>/<td> implied closes handled)."""

    IMPLIES_END = {"li": {"li"}, "p": {"p"}, "td": {"td", "th"}, "th": {"td", "th"},
                   "tr": {"tr", "td", "th"}, "option": {"option"}}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = El("document", {})
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        d = {}
        for k, v in attrs:
            if k not in d:
                d[k] = v if v is not None else ""
        closes = self.IMPLIES_END.get(tag, set())
        while len(self.stack) > 1 and self.stack[-1].tag in closes:
            self.stack.pop()
        el = El(tag, d)
        self.stack[-1].children.append(el)
        if tag not in VOID_TAGS:
            self.stack.append(el)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID_TAGS and self.stack[-1].tag == tag:
            self.stack.pop()

    def handle_endtag(self, tag):
        if tag in VOID_TAGS:
            return
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        if data:
            self.stack[-1].children.append(data)


def parse_dom(text: str) -> El:
    b = DomBuilder()
    b.feed(text)
    return b.root


def find_first(el: El, pred):
    if pred(el):
        return el
    for c in el.children:
        if isinstance(c, El):
            r = find_first(c, pred)
            if r is not None:
                return r
    return None


# ------------------------------------------------- jQuery html injection ----
JQ_RE = re.compile(r"\$\('\.([A-Za-z0-9_-]+)'\)\.html\(('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")\);")


def unescape_js(s: str) -> str:
    body = s[1:-1]
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            n = body[i + 1]
            out.append({"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"'}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def apply_jquery(text: str) -> str:
    injections: dict[str, str] = {}
    for cls, raw in JQ_RE.findall(text):
        injections[cls] = unescape_js(raw)
    for cls, content in injections.items():
        pat = re.compile(
            r"<(\w+)([^>]*\bclass=\"[^\"]*\b" + re.escape(cls) + r"\b[^\"]*\"[^>]*)>\s*</\1>")
        text = pat.sub(lambda m: content, text)
    return text


# ------------------------------------------------------------ converter ----
class Converter:
    def __init__(self, link_map: dict[str, str]):
        self.link_map = link_map
        self.images: dict[str, str] = {}  # site-rel path -> flat filename
        self.current_path = "index.html"
        self.current_ns = "Main"
        self.current_title = "首页"
        self.extra_pages: list[tuple[str, str, str]] = []  # (ns, title, wikitext)

    # -- helpers --
    @staticmethod
    def ws(text: str) -> str:
        return re.sub(r"\s+", " ", text)

    def flat_image(self, src: str) -> str:
        rel = normalize_asset(src, getattr(self, "current_path", "index.html"))
        if rel is None:
            return ""
        if rel not in self.images:
            self.images[rel] = rel[len("images/"):].replace("/", "-")
        return self.images[rel]

    def node_color(self, el: El) -> str | None:
        for c in el.cls():
            if c in CLASS_COLORS:
                return CLASS_COLORS[c]
        style = el.attr("style") or ""
        m = re.search(r"(?:^|;)\s*color\s*:\s*([^;]+)", style)
        if m:
            v = m.group(1).strip()
            if re.fullmatch(r"#[0-9a-fA-F]{3,8}", v):
                return v
            named = {"green": "#008000", "red": "#ff0000", "blue": "#0000ff",
                     "orange": "#ffa500", "gray": "#808080", "white": "#ffffff",
                     "black": "#000000", "purple": "#800080", "#999": "#999999"}
            return named.get(v.lower())
        return None

    # -- inline emission: returns single-line wikitext --
    def inline(self, nodes: list) -> str:
        parts: list[str] = []
        for n in nodes:
            parts.append(self.inline_one(n))
        return "".join(parts)

    def inline_one(self, n) -> str:
        if isinstance(n, str):
            return self.ws(n).replace("|", "&#124;")
        tag = n.tag
        if tag in SKIP_TAGS:
            return ""
        if tag == "br":
            return "<br>"
        if tag == "img":
            return self.emit_img(n)
        if tag == "div" and "kireage" in n.cls():
            return self.emit_sharpness(n)
        if tag == "span" and "hasei" in n.cls():
            # 派生树符号（┗ ┣ ┃）：小一号，窄屏下给武器名让位
            txt = self.text_of(n.children).strip()
            return f"<small>{txt}</small>" if txt else ""
        if tag == "a":
            return self.emit_a(n)
        if tag in ("b", "strong"):
            inner = self.inline(n.children).strip()
            return f"'''{inner}'''" if inner else ""
        if tag in ("i", "em"):
            inner = self.inline(n.children).strip()
            return f"''{inner}''" if inner else ""
        if tag in ("ul", "ol", "table"):
            return self.flatten_blockish(n)
        # transparent inline (span/font/small/sup/sub/u/s/big/abbr/...)
        inner = self.inline(n.children)
        color = self.node_color(n)
        if color and inner.strip():
            wrapped = f'<font color="{color}">{inner}</font>'
            # 括号注记（[生产][XX] 等）再小一号：避免把武器名挤到下一行
            if re.fullmatch(r"(\[[^\[\]]{1,8}\]\s*)+", inner.strip()):
                wrapped = f"<small>{wrapped}</small>"
            return wrapped
        if not set(n.cls()).isdisjoint(BOLD_CLASSES):
            s = inner.strip()
            return f"'''{s}'''" if s else inner
        return inner

    def flatten_blockish(self, el: El) -> str:
        """Nested table/list in inline context: rows joined by <br>, cells by ' / '."""
        rows = []
        for c in el.children:
            if isinstance(c, El) and c.tag == "tr":
                cells = [self.inline(x.children).strip() for x in c.children
                         if isinstance(x, El) and x.tag in ("td", "th")]
                rows.append(" / ".join(x for x in cells if x))
            elif isinstance(c, El) and c.tag == "li":
                rows.append(self.inline(c.children).strip())
            elif isinstance(c, El) and c.tag not in SKIP_TAGS:
                sub = self.flatten_blockish(c).strip()
                if sub:
                    rows.append(sub)
        return "<br>".join(r for r in rows if r)

    def emit_img(self, el: El) -> str:
        src = el.attr("src") or ""
        flat = self.flat_image(src)
        if not flat:
            return ""
        w = el.attr("width") or ""
        m = re.fullmatch(r"(\d+)\s*px?", w)
        if m:
            px = m.group(1)
        else:
            nat = natural_width(IMAGES / flat)
            # 小图标（武器剪影 21/16px）统一 16px：贴近原站视觉且省列宽
            px = "16" if nat is not None and nat <= 24 else str(nat or "")
        opts = f"|{px}px" if px else ""
        return f"[[File:{flat}{opts}]]"

    # 斩位条压缩后每条最长点数（原站 10px 小点阵 ≈ 一列宽；小字号加密点数保留条形观感）
    SHARPNESS_MAX_DOTS = 22

    def emit_sharpness(self, el: El) -> str:
        """斩位（锐利度）条：krN 色段按行分组（换行分两条），等比缩放到最长 SHARPNESS_MAX_DOTS 点，
        <small> 小字号 + <br> 强制两行（对齐原站上下两条的视觉）"""
        lines: list[list[tuple[str, int]]] = [[]]
        for c in el.children:
            if isinstance(c, str):
                if "\n" in c and lines[-1]:
                    lines.append([])
                continue
            if not isinstance(c, El) or c.tag != "span":
                continue
            color = next((CLASS_COLORS[k] for k in c.cls() if k in CLASS_COLORS), None)
            count = sum(len(x) for x in c.children if isinstance(x, str))
            if color and count > 0:
                lines[-1].append((color, count))
        lines = [l for l in lines if l]
        if not lines:
            return ""
        maxlen = max(sum(n for _, n in l) for l in lines)
        scale = min(1.0, self.SHARPNESS_MAX_DOTS / maxlen)
        out_lines: list[str] = []
        for l in lines:
            parts = []
            for color, count in l:
                dots = "." * round(count * scale)
                if dots:
                    parts.append(f'<font color="{color}">{dots}</font>')
            out_lines.append("".join(parts))
        return "<small>" + "<br>".join(out_lines) + "</small>"

    def emit_a(self, el: El) -> str:
        href = el.attr("href") or ""
        cls = el.cls()
        if "panel_btn" in cls or href in ("#", ""):
            return ""
        inner = self.inline(el.children).strip()
        target = normalize_link(self.current_path, href)
        if target is not None:
            title = self.link_map.get(target)
            if title:
                return f"[[{title}]]" if title == inner else f"[[{title}|{inner}]]"
            return inner  # dead link -> plain text
        if href.startswith(("http://", "https://")):
            return f"[{href} {inner}]" if inner else ""
        return inner

    # -- block emission: returns list of wikitext block chunks --
    def blocks(self, nodes: list) -> list[str]:
        out: list[str] = []
        for n in nodes:
            out.extend(self.block_one(n))
        return out

    def block_one(self, n) -> list[str]:
        if isinstance(n, str):
            t = n.strip()
            return [t] if t else []
        if n.attr("id") in ("bread", "navi1"):
            return []
        tag = n.tag
        if tag in SKIP_TAGS:
            return []
        if tag == "h2":
            return []  # page title duplicate
        if tag in ("h3", "h4", "h5", "h6"):
            level = {"h3": 2, "h4": 3, "h5": 4, "h6": 4}[tag]
            text = self.inline(n.children).strip()
            return [f"{'=' * level}{text}{'=' * level}"] if text else []
        if tag == "table":
            return self.emit_table(n)
        if tag in ("ul", "ol"):
            lines = self.emit_list(n, marker="#" if tag == "ol" else "*", depth=0)
            return lines if lines else []
        if tag == "hr":
            return ["----"]
        if tag in ("p", "div", "center", "blockquote", "section", "article", "main"):
            if n.attr("id") in ("bread", "navi1") or not set(n.cls()).isdisjoint(SKIP_CLASSES):
                return []
            if "adslot" in " ".join(n.cls()):
                return []
            if "panel-heading" in n.cls():
                text = self.inline(n.children).strip()
                return [f"=={text}=="] if text else []
            return self.blocks(n.children)
        if tag == "br":
            return []
        # inline elements at block level -> paragraph
        text = self.inline_one(n).strip()
        return [text] if text else []

    def emit_list(self, el: El, marker: str, depth: int) -> list[str]:
        lines: list[str] = []
        for c in el.children:
            if not isinstance(c, El):
                continue
            if c.tag == "li":
                # split inline prefix / nested lists
                head: list = []
                nested: list[str] = []
                for x in c.children:
                    if isinstance(x, El) and x.tag in ("ul", "ol"):
                        m2 = "#" if x.tag == "ol" else "*"
                        nested.extend(self.emit_list(x, m2, depth + 1))
                    else:
                        head.append(x)
                text = self.inline(head).strip()
                if text or nested:
                    lines.append(f"{marker * (depth + 1)} {text}".rstrip())
                lines.extend(nested)
            elif c.tag in ("ul", "ol"):
                m2 = "#" if c.tag == "ol" else "*"
                lines.extend(self.emit_list(c, m2, depth + 1))
        return lines

    @staticmethod
    def row_cells(row: El) -> list[El]:
        return [c for c in row.children
                if isinstance(c, El) and c.tag in ("td", "th")]

    @staticmethod
    def is_sep_row(row: El) -> bool:
        cells = Converter.row_cells(row)
        return len(cells) == 1 and "sub_th" in cells[0].cls()

    def text_of(self, nodes: list) -> str:
        out: list[str] = []
        for n in nodes:
            if isinstance(n, str):
                out.append(n)
            elif n.tag not in SKIP_TAGS:
                out.append(self.text_of(n.children))
        return self.ws("".join(out))

    def table_lines(self, rows: list[El]) -> list[str]:
        lines = ["{|"]
        for row in rows:
            cells = self.row_cells(row)
            if not cells:
                continue
            contents = [self.cell_content(c) for c in cells]
            big = next((i for i, s in enumerate(contents)
                        if len(s) > CELL_SPLIT_CHARS), -1)
            has_rowspan = any(
                (c.attr("rowspan") or "").isdigit() and int(c.attr("rowspan") or "1") > 1
                for c in cells)
            if big >= 0 and not has_rowspan:
                # 超大单元格：前导格加 rowspan 跨块，条目块各自成行（解析器按占位列对齐）
                parts = contents[big].split("<br>")
                chunks = ["<br>".join(parts[i:i + CELL_SPLIT_ITEMS])
                          for i in range(0, len(parts), CELL_SPLIT_ITEMS)]
                n = len(chunks)
                lines.append("|-")
                for i in range(big):
                    lines.append(f'| rowspan="{n}" | {contents[i]}')
                lines.append(f"| {chunks[0]}")
                for k in range(1, n):
                    lines.append("|-")
                    lines.append(f"| {chunks[k]}")
                    if k == n - 1:
                        for i in range(big + 1, len(contents)):
                            lines.append(f"| {contents[i]}")
                continue
            lines.append("|-")
            for cell, content in zip(cells, contents):
                attrs = []
                for a in ("rowspan", "colspan"):
                    v = cell.attr(a)
                    if v and v.isdigit() and int(v) > 1:
                        attrs.append(f'{a}="{int(v)}"')
                head = cell.tag == "th"
                if head:
                    w = cell.attr("width") or ""
                    if "斩位" in content:
                        # 手机适配：原站斩位列 15%（桌面比例）装不下压缩后的色点条
                        w = "22%"
                    elif "武器名" in content:
                        # 深层派生符号（┃┃┗+图标+名字）在 50% 下差十几个像素
                        w = "54%"
                    if re.fullmatch(r"\d+(?:\.\d+)?%", w):
                        # 原站列宽比例（如武器名列 50%）：传给渲染端按比例分配列宽
                        attrs.append(f'style="width:{w}"')
                # 块式表格：每格独占一行，行首单个 | / !（|| / !! 是同行链式语法，
                # 行首使用会被解析成字面竖线且单元格不再分列）
                prefix = "!" if head else "|"
                attr_txt = (" " + " ".join(attrs) + " | ") if attrs else " "
                lines.append(f"{prefix}{attr_txt}{content}")
        lines.append("|}")
        return lines

    def emit_table(self, el: El) -> list[str]:
        # 入手/用途大表（t_sp：标签格 + 数百条目内容格）：改写为 标签+列表，
        # 单格巨段落（<br> 连接数百条）会拖垮 ArkUI 段落布局
        if "t_sp" in el.cls() and len(self.text_of(el.children)) > 3_000:
            out = self.emit_list_table(el)
            if out:
                return out
        rows: list[El] = []
        self.collect_rows(el, rows)
        rows = [r for r in rows if self.row_cells(r)]
        if len(rows) == 0:
            return []
        if len(rows) > SPLIT_TABLE_MIN_ROWS:
            split = self.try_split_table(rows)
            if split is not None:
                return split
        return ["\n".join(self.table_lines(rows))]

    def emit_list_table(self, el: El) -> list[str]:
        """两列「标签/条目」表 → 粗体标签行 + 每条目一行的列表块"""
        rows: list[El] = []
        self.collect_rows(el, rows)
        out: list[str] = []
        for row in rows:
            cells = self.row_cells(row)
            if len(cells) == 2:
                label = self.inline(cells[0].children).strip()
                label = re.sub(r"<br>\s*", " ", label).strip()
                body = self.cell_content(cells[1])
                items = [it.strip() for it in body.split("<br>") if it.strip()]
                if label:
                    out.append(f"'''{label}'''")
                out.extend(f"* {it}" for it in items)
            elif cells:
                out.append("\n".join(self.table_lines([row])))
        return out

    def try_split_table(self, rows: list[El]) -> list[str] | None:
        """超大表拆子页面；主页面只留索引表。
        路径一：sub_th 分隔行（■xx派生，武器树）；
        路径二：首列 rowspan 块 = 一组（防具稀有度表：一块 = 剑士/枪手一整套）。
        原站用 JS 折叠面板控制展开，离线 eager 渲染数百行会阻塞主线程。"""
        header: El | None = None
        first = self.row_cells(rows[0])
        if first and all(c.tag == "th" for c in first):
            header = rows[0]
        body = rows[1:] if header is not None else rows

        families: list[tuple[str, list[El]]] = []
        head_word = "系列"
        if sum(1 for r in body if self.is_sep_row(r)) >= 2:
            head_word = "派生"
            for r in body:
                if self.is_sep_row(r):
                    name = self.text_of(self.row_cells(r)[0].children).strip().lstrip("■").strip()
                    families.append((name or f"派生{len(families) + 1}", []))
                elif families:
                    families[-1][1].append(r)
        else:
            groups = self.rowspan_groups(body)
            if groups is not None:
                families = groups
            else:
                families = self.chunk_groups(body)
                head_word = "分块"
        families = [(n, rs) for n, rs in families if rs]
        if len(families) < 2:
            return None
        ns = self.current_ns
        prefix = "" if ns == "Main" else ns + ":"
        lines = ["{|", "|-", f"! {head_word}"]
        for name, frows in families:
            page = f"{prefix}{self.current_title}/{name}"
            lines.append("|-")
            lines.append(f"| [[{page}|{name}]]")
            body_rows = ([header] if header is not None else []) + frows
            text = f"=={name}==\n" + "\n".join(self.table_lines(body_rows))
            self.extra_pages.append((ns, f"{self.current_title}/{name}", text))
        lines.append("|}")
        return ["\n".join(lines)]

    def rowspan_groups(self, body: list[El]) -> list[tuple[str, list[El]]] | None:
        """按首列 rowspan 块分组（防具表）；同名相邻块合并（剑士+枪手同系列），
        无链接的块并入前组。返回 None 表示不适合该拆法。"""
        bounds: list[int] = []
        for i, r in enumerate(body):
            cells = self.row_cells(r)
            if not cells:
                continue
            v = cells[0].attr("rowspan")
            if v and v.isdigit() and int(v) > 1:
                bounds.append(i)
        # 超长表（如技能页数百行）放宽分组门槛；普通表保持 ≥6 块才值得拆
        min_bounds, min_groups = (2, 2) if len(body) > 250 else (6, 4)
        if len(bounds) < min_bounds:
            return None
        groups: list[tuple[str, list[El]]] = []
        for k, start in enumerate(bounds):
            end = bounds[k + 1] if k + 1 < len(bounds) else len(body)
            label = self.row_group_label(body[start])
            if label is None and groups:
                groups[-1][1].extend(body[start:end])
                continue
            if label is not None and groups and groups[-1][0] == label:
                groups[-1][1].extend(body[start:end])
                continue
            groups.append((label or f"系列{len(groups) + 1}", body[start:end]))
        return groups if len(groups) >= 4 else None

    def chunk_groups(self, body: list[El]) -> list[tuple[str, list[El]]]:
        """无结构边界的大表按固定行数切块；含 rowspan 的表不切（跨块会截断）。"""
        if len(body) < CHUNK_TABLE_ROWS * 2:
            return []
        for r in body:
            for c in self.row_cells(r):
                v = c.attr("rowspan")
                if v and v.isdigit() and int(v) > 1:
                    return []
        groups: list[tuple[str, list[El]]] = []
        for k in range(0, len(body), CHUNK_TABLE_ROWS):
            chunk = body[k:k + CHUNK_TABLE_ROWS]
            label = self.row_chunk_label(chunk[0])
            groups.append((f"{len(groups) + 1}. {label}" if label else f"第{len(groups) + 1}部分", chunk))
        return groups

    def row_chunk_label(self, row: El) -> str:
        first_a = find_first(row, lambda e: e.tag == "a" and bool(e.attr("href")))
        if first_a is None:
            t = self.text_of(row.children).strip()
            return t[:12]
        t = self.text_of(first_a.children).strip()
        return t[:16]

    def row_group_label(self, row: El) -> str | None:
        first_a = find_first(row, lambda e: e.tag == "a" and bool(e.attr("href")))
        if first_a is None:
            return None
        target = normalize_link(self.current_path, first_a.attr("href") or "")
        if target is None:
            return None
        title = self.link_map.get(target)
        if title is None:
            return None
        ci = title.find(":")
        return title[ci + 1:] if ci >= 0 else title

    def collect_rows(self, el: El, out: list):
        for c in el.children:
            if not isinstance(c, El):
                continue
            if c.tag == "tr":
                out.append(c)
            elif c.tag in ("thead", "tbody", "tfoot"):
                self.collect_rows(c, out)

    def cell_content(self, cell: El) -> str:
        # block children inside cell -> flatten inline-ish
        parts = []
        for c in cell.children:
            if isinstance(c, str):
                parts.append(self.ws(c))
            elif c.tag == "br":
                parts.append("<br>")
            else:
                parts.append(self.inline_one(c))
        s = "".join(parts)
        s = re.sub(r"<br>\s*", "<br>", s)
        s = s.strip()
        # 派生符号与图标粘连：省一格空格，窄屏深层符号才挤得下武器名
        s = re.sub(r"(</small>)\s+(\[\[File:)", r"\1\2", s)
        # 括号注记（[生产][购入][XX] 等）小字号：武器名后不至于被挤到下一行
        if re.fullmatch(r"(\[[^\[\]]{1,8}\]\s*)+", s):
            s = f"<small>{s}</small>"
        # 孔槽装饰串（◯ - - 等）：小字号防折行（连字符在 CJK 字体下偏宽）；去掉内空格更紧凑
        elif re.fullmatch(r"([◯○\-]\s*)+", s):
            compact = re.sub(r"\s+", "", s)
            s = f"<small>{compact}</small>"
        return s


def normalize_asset(src: str, base_rel: str = "index.html") -> str | None:
    if not src or src.startswith(("http://", "https://", "data:")):
        return None
    abs_url = urllib.parse.urljoin(SITE + base_rel, src)
    if not abs_url.startswith(SITE):
        return None
    rel = urllib.parse.urlsplit(abs_url).path
    if not rel.startswith(BASE_PATH):
        return None
    rel = rel[len(BASE_PATH):]
    if not rel.startswith("images/"):
        return None
    return rel


# ------------------------------------------------------ meta / two-pass ----
TITLE_RE = re.compile(r"<title>(.*?)</title>", re.S)
BREAD_RE = re.compile(r'<ul id="bread">(.*?)</ul>', re.S)
ACTIVE_LI_RE = re.compile(r'<li class="active">(.*?)</li>', re.S)
TAG_RE = re.compile(r"<[^>]+>")


_DIM_CACHE: dict[str, int] = {}


def natural_width(path: Path) -> int | None:
    """读图片文件头取原始宽度（gif/png），失败返回 None"""
    key = str(path)
    if key in _DIM_CACHE:
        wv = _DIM_CACHE[key]
        return wv if wv > 0 else None
    try:
        with open(path, "rb") as f:
            head = f.read(33)
        wv = 0
        if head[:6] in (b"GIF87a", b"GIF89a"):
            wv = struct.unpack("<H", head[6:8])[0]
        elif head[:8] == b"\x89PNG\r\n\x1a\n":
            wv = struct.unpack(">I", head[16:20])[0]
    except OSError:
        wv = 0
    _DIM_CACHE[key] = wv
    return wv if wv > 0 else None


def page_meta(html: str, rel_path: str) -> tuple[str, str, int]:
    """-> (ns, title, pageid)"""
    pageid = 0
    m = re.search(r"(\d+)\.html$", rel_path)
    if m:
        pageid = int(m.group(1))
    if rel_path == "index.html":
        return "Main", "首页", 0
    m = TITLE_RE.search(html)
    title = m.group(1).split("|")[0].strip() if m else ""
    ns = ""
    bm = BREAD_RE.search(html)
    if bm:
        am = ACTIVE_LI_RE.search(bm.group(1))
        if am:
            ns = TAG_RE.sub("", am.group(1)).strip()
    if not title:
        title = f"页面{pageid}"
    return (ns or "Main"), title, pageid


HEADING_RE = re.compile(r"^==([^=].*[^=])==$")
# wikitext 粗体是三个单引号 '''，不是星号
SECTION_MARK_RE = re.compile(r"^(==[^=].*[^=]==|'''.+''')$")


def heading_plain(line: str) -> str:
    s = line.strip()
    if s.startswith("=="):
        s = HEADING_RE.match(s).group(1)
    else:
        s = s.strip("*'").strip()
    s = re.sub(r"\[\[(?:File|文件):[^\]]*\]\]", "", s)  # 图片不计入标题
    s = re.sub(r"\[\[[^\]|]*\|([^\]]*)\]\]", r"\1", s)  # [[a|b]] -> b
    s = re.sub(r"\[\[([^\]]*)\]\]", r"\1", s)  # [[a]] -> a
    s = re.sub(r"</?font[^>]*>", "", s)
    s = s.replace("'''", "").replace("''", "").replace("[", "").replace("]", "")
    return re.sub(r"\s+", " ", s).strip()


def split_page_text(text: str) -> tuple[str, list[str]] | None:
    """超大页按 ==标题== / '''粗体标签''' 行切分：返回 (intro, [sections])"""
    if len(text) < PAGE_SPLIT_MIN_CHARS:
        return None
    lines = text.split("\n")
    idxs = [i for i, l in enumerate(lines) if SECTION_MARK_RE.match(l.strip())]
    if len(idxs) < PAGE_SPLIT_MIN_SECTIONS:
        return None
    intro = "\n".join(lines[:idxs[0]]).strip()
    sections: list[str] = []
    for k, i in enumerate(idxs):
        end = idxs[k + 1] if k + 1 < len(idxs) else len(lines)
        sec = "\n".join(lines[i:end]).strip()
        if sec:
            sections.append(sec)
    return intro, sections


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--convert-only", action="store_true")
    ap.add_argument("--images-only", action="store_true",
                    help="download images listed in images.json (needs a prior conversion)")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--no-images", action="store_true")
    args = ap.parse_args()

    if args.images_only:
        IMAGES.mkdir(exist_ok=True)
        mapping = json.loads((OUT / "images.json").read_text(encoding="utf-8"))
        conv = Converter({})
        conv.images = mapping
        download_images(conv)
        return

    if not args.convert_only:
        pages = crawl(args.limit)
        print(f"crawled: {len(pages)} pages")
    else:
        pages = sorted(str(p.relative_to(CACHE)).replace("\\", "/")
                       for p in CACHE.rglob("*.html"))
        print(f"cache: {len(pages)} pages")

    # pass 1: meta + title assignment (collision -> append id)
    metas: dict[str, tuple[str, str, int]] = {}
    link_map: dict[str, str] = {}
    used: dict[str, str] = {}
    for rel in pages:
        html = apply_jquery((CACHE / rel).read_text(encoding="utf-8"))
        (CACHE / rel).write_text(html, encoding="utf-8")
        ns, title, pid = page_meta(html, rel)
        key = f"{ns}:{title}"
        if key in used:
            title = f"{title}({pid})"
            key = f"{ns}:{title}"
        metas[rel] = (ns, title, pid)
        link_map[rel] = title if ns == "Main" else f"{ns}:{title}"
        used[key] = rel
    collisions = [v for v in metas.values() if "(" in v[1] and v[1].endswith(")")]
    ns_names = sorted({v[0] for v in metas.values()})

    # pass 2: convert
    if PAGES.exists():
        shutil.rmtree(PAGES)
    conv = Converter(link_map)
    manifest = []
    for rel in pages:
        ns, title, pid = metas[rel]
        html = (CACHE / rel).read_text(encoding="utf-8")  # jquery already applied
        dom = parse_dom(html)
        main1 = find_first(dom, lambda e: e.attr("id") == "main_1")
        body = find_first(dom, lambda e: e.tag == "body")
        root = main1 if main1 is not None else (body or dom)
        conv.current_path = rel
        conv.current_ns = ns
        conv.current_title = title
        conv.extra_pages = []
        chunks = conv.blocks(root.children) if root.tag != "document" else conv.blocks(root.children)
        text = "\n".join(chunks)
        text = re.sub(r"[ \t]+\n", "\n", text)
        text = re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"
        # 页面级拆分：超大页按 ==标题== 切子页面（防具稀有度：panel 标题 + 小表 ×77）
        sp = split_page_text(text)
        if sp is not None:
            intro, sections = sp
            seen_labels: set[str] = set()
            entries: list[tuple[str, str]] = []  # (子页标签, 子页 wikitext)
            for sec in sections:
                label = heading_plain(sec.split("\n", 1)[0]) or f"部分{len(entries) + 1}"
                base = label
                k = 2
                while label in seen_labels:
                    label = f"{base} {k}"
                    k += 1
                seen_labels.add(label)
                if len(sec) > SECTION_MAX_CHARS:
                    # 单节仍超大（道具[用途]上千条目）：按条目再切块
                    sec_lines = sec.split("\n")
                    head2 = sec_lines[0]
                    items = sec_lines[1:]
                    for c in range(0, len(items), SECTION_CHUNK_ITEMS):
                        chunk = items[c:c + SECTION_CHUNK_ITEMS]
                        sub = f"{label} {c // SECTION_CHUNK_ITEMS + 1}"
                        entries.append((sub, head2 + "\n" + "\n".join(chunk)))
                else:
                    entries.append((label, sec))
            lines = ["{|", "|-", "! 系列"]
            for sub_label, sub_text in entries:
                lines.append("|-")
                lines.append(f"| [[{ns}:{title}/{sub_label}|{sub_label}]]" if ns != "Main"
                             else f"| [[{title}/{sub_label}|{sub_label}]]")
                conv.extra_pages.append((ns, f"{title}/{sub_label}", sub_text))
            lines.append("|}")
            text = (intro + "\n\n" if intro else "") + "\n".join(lines) + "\n"
        ns_dir = fs_safe(ns)
        title_file = fs_safe(title)
        out_path = PAGES / ns_dir / f"{title_file}.wiki"
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(text, encoding="utf-8")
        manifest.append({
            "title": link_map[rel],
            "ns": 0 if ns == "Main" else 100,
            "pageid": pid,
            "path": f"{ns_dir}/{title_file}.wiki",
            "bytes": out_path.stat().st_size,
        })
        # 大表拆分出的子页面（如武器派生家族）
        for fns, ftitle, ftext in conv.extra_pages:
            fdir = fs_safe(fns)
            ffile = fs_safe(ftitle)
            fpath = PAGES / fdir / f"{ffile}.wiki"
            fpath.parent.mkdir(parents=True, exist_ok=True)
            fpath.write_text(ftext.strip() + "\n", encoding="utf-8")
            manifest.append({
                "title": ftitle if fns == "Main" else f"{fns}:{ftitle}",
                "ns": 0 if fns == "Main" else 100,
                "pageid": pid,
                "path": f"{fdir}/{ffile}.wiki",
                "bytes": fpath.stat().st_size,
            })
    print(f"converted: {len(manifest)} pages; ns={ns_names}; collisions={len(collisions)}")

    manifest.sort(key=lambda e: e["title"])
    (OUT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    summary = {
        "site": "MHXX 怪物猎人双十字攻略大全",
        "url": SITE,
        "exported_at": datetime.now(timezone(timedelta(hours=8))).isoformat(timespec="seconds"),
        "total_pages": len(manifest),
        "total_images": len(conv.images),
    }
    (OUT / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
    (OUT / "images.json").write_text(
        json.dumps(conv.images, ensure_ascii=False, indent=1), encoding="utf-8")

    # images
    if args.no_images:
        return
    IMAGES.mkdir(exist_ok=True)
    download_images(conv)


def download_images(conv: Converter) -> None:
    todo = {rel: flat for rel, flat in conv.images.items()
            if not (IMAGES / flat).exists()}
    print(f"images: {len(todo)} to download ({len(conv.images) - len(todo)} cached)")
    done = fail = 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        futs = {pool.submit(fetch, SITE + rel): rel for rel in todo}
        for fut in as_completed(futs):
            rel = futs[fut]
            data = fut.result()
            if data is None:
                fail += 1
                continue
            (IMAGES / conv.images[rel]).write_bytes(data)
            done += 1
    print(f"images: {done} downloaded, {fail} failed")


if __name__ == "__main__":
    main()
