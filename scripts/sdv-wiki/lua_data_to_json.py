# Convert Lua data modules (pure `return { ... }` table literals) to JSON pages
# under out/sdv-datapages/ as Module:Data/<name>.wiki (JSON body).
import json
import re
from pathlib import Path

OUT = Path(__file__).parent / "out"
DUMP = OUT / "sdv_full.jsonl"
DEST = OUT / "sdv-datapages"
DEST.mkdir(exist_ok=True)

# data modules consumed by the 14 ported modules (Object/Furniture/Weapons data
# have no consumer among them -> skip)
CONVERT = [
    "Module:GiftsByItem/data",
    "Module:ID/data/en",
    "Module:ID/data/zh",
    "Module:Items/zh/id/name",
    "Module:Items/zh/name/desc",
    "Module:Items/zh/ids/name",
    "Module:Items/zh/name/ids",
    "Module:Items/zh/id/desc",
    "Module:Items/en/id/name",
    "Module:Items/en/ids/name",
    "Module:Items/en/name/ids",
    "Module:Items/overrides/name",
    "Module:Items/overrides/description",
    "Module:Items/overrides/id",
    "Module:Items/overrides/items",
]


class LuaParseError(Exception):
    pass


class Parser:
    def __init__(self, src: str):
        # strip comments (naive but data modules have no strings containing --)
        src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
        src = re.sub(r"--[^\n]*", "", src)
        self.s = src
        self.i = 0

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t\r\n":
            self.i += 1

    def peek(self):
        self.ws()
        return self.s[self.i] if self.i < len(self.s) else ""

    def eat(self, tok: str):
        self.ws()
        if not self.s.startswith(tok, self.i):
            raise LuaParseError(f"expected {tok!r} at {self.i}: "
                                f"{self.s[self.i:self.i + 30]!r}")
        self.i += len(tok)

    def parse_table(self):
        self.eat("{")
        obj = {}
        auto_idx = 1
        while True:
            c = self.peek()
            if c == "}":
                self.i += 1
                return obj
            if c == "," or c == ";":
                self.i += 1
                continue
            # key?
            if c == "[":
                self.i += 1
                key = self.parse_value()
                self.eat("]")
                self.eat("=")
                obj[self.key_str(key)] = self.parse_value()
            else:
                save = self.i
                m = re.match(r"[A-Za-z_][A-Za-z0-9_]*\s*=", self.s[self.i:])
                if m and not re.match(r"(true|false|nil)\s*=", self.s[self.i:]):
                    name = m.group(0).rstrip("= \t")
                    self.i += len(m.group(0))
                    obj[name] = self.parse_value()
                else:
                    self.i = save
                    obj[str(auto_idx)] = self.parse_value()
                    auto_idx += 1
            # allow optional separator
            c = self.peek()
            if c in ",;":
                self.i += 1

    @staticmethod
    def key_str(k):
        if isinstance(k, float) and k.is_integer():
            return str(int(k))
        return str(k)

    def parse_value(self):
        c = self.peek()
        if c == "{":
            return self.parse_table()
        if c == '"' or c == "'":
            return self.parse_string()
        if self.s.startswith("[[", self.i):
            self.i += 2
            end = self.s.find("]]", self.i)
            val = self.s[self.i:end]
            self.i = end + 2
            return val
        m = re.match(r"-?\d+\.\d+(?:[eE][-+]?\d+)?|-?\d+", self.s[self.i:])
        if m:
            self.i += len(m.group(0))
            t = m.group(0)
            return float(t) if ("." in t or "e" in t or "E" in t) else int(t)
        m = re.match(r"true|false|nil", self.s[self.i:])
        if m:
            self.i += len(m.group(0))
            return {"true": True, "false": False, "nil": None}[m.group(0)]
        raise LuaParseError(f"unexpected value at {self.i}: "
                            f"{self.s[self.i:self.i + 40]!r}")

    def parse_string(self):
        quote = self.s[self.i]
        self.i += 1
        out = []
        while True:
            ch = self.s[self.i]
            if ch == "\\":
                nxt = self.s[self.i + 1]
                mapping = {"n": "\n", "t": "\t", '"': '"', "'": "'",
                           "\\": "\\", "r": "\r"}
                if nxt in mapping:
                    out.append(mapping[nxt])
                    self.i += 2
                elif nxt == "\n":  # backslash-newline continuation
                    self.i += 2
                else:
                    out.append(nxt)
                    self.i += 2
            elif ch == quote:
                self.i += 1
                return "".join(out)
            else:
                out.append(ch)
                self.i += 1


def convert():
    mods = {}
    for line in DUMP.read_text(encoding="utf-8").splitlines():
        rec = json.loads(line)
        if rec["ns"] == 828:
            mods[rec["title"]] = rec["content"]
    for title in CONVERT:
        src = mods.get(title)
        if src is None:
            print(f"  ? not in dump: {title}")
            continue
        p = Parser(src)
        p.ws()
        m = re.match(r"return", p.s[p.i:])
        if not m:
            print(f"  ! not a `return {{}}` module: {title}")
            continue
        p.i += len("return")
        try:
            data = p.parse_table()
            p.ws()
            trailing = p.s[p.i:].strip()
            if trailing:
                raise LuaParseError(f"trailing content: {trailing[:40]!r}")
        except LuaParseError as e:
            print(f"  ! PARSE FAIL {title}: {e}")
            continue
        body = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        name = title.split(":", 1)[1].replace("/", "_")
        page_file = DEST / f"{name}.wiki"
        page_file.write_text(body, encoding="utf-8")
        n_keys = len(data)
        print(f"  ok {title}: {n_keys} top keys, {len(body)/1e3:.0f} KB JSON")


if __name__ == "__main__":
    convert()
