# Systematic leak sweep: load page, scroll full page capturing layout dumps at
# each stop, grep rendered text nodes for unparsed-syntax patterns.
import json
import subprocess
import sys
import time
from pathlib import Path

DEVE = r"C:\Users\69406\AppData\Roaming\npm\devecocli.cmd"
HDC = r"C:\Program Files\Huawei\DevEco Studio\SDK\default\openharmony\toolchains\hdc.exe"
OUT = Path(__file__).parent.parent.parent / ".qoder" / "sweep"
OUT.mkdir(parents=True, exist_ok=True)
SITE = "sdv-zh"
LEAK_RE = [
    "{{", "}}", "{{{", "#switch", "#if:", "#invoke", "#tag:",
    "id=\"", "colspan=", "rowspan=", "style=\"background",
    "<span", "<div", "<table", "</td", "</tr", "<nowiki",
    "data-sort-value", "src=\"Template", "class=\"wikitable",
    "|-", "||", "FULLURL", "templatestyles",
]


def run(cmd, timeout=60):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                          encoding="utf-8", errors="replace")


def b64(s):
    import base64
    return base64.b64encode(s.encode()).decode()


def sweep_page(title):
    run([HDC, "shell", "aa", "force-stop", "io.github.smdsbz.ohmywiki"])
    time.sleep(1)
    run([HDC, "shell", "aa", "start", "-a", "EntryAbility",
         "-b", "io.github.smdsbz.ohmywiki",
         "--ps", "pageB64", b64(title), "--ps", "siteB64", b64(SITE)])
    time.sleep(8)
    leaks = []
    n_stops = 0
    seen_texts = set()
    for stop in range(14):  # 最多 14 档滚动
        r = run([DEVE, "ui", "layout", "--device", "127.0.0.1:6555",
                 "--format", "json"], timeout=90)
        raw = r.stdout
        s = raw.find("{")
        if s < 0:
            break
        depth = 0
        e = -1
        for i in range(s, len(raw)):
            if raw[i] == "{":
                depth += 1
            elif raw[i] == "}":
                depth -= 1
                if depth == 0:
                    e = i + 1
                    break
        if e < 0:
            break
        try:
            d = json.loads(raw[s:e])
        except Exception:
            break
        texts = []

        def walk(n):
            t = str(n.get("text") or "").strip()
            if 0 < len(t) < 300:
                texts.append(t)
            for c in n.get("children") or []:
                walk(c)

        walk(d)
        new = [t for t in texts if t not in seen_texts]
        if stop > 0 and not new:
            break  # 页面滚到底（无新内容）
        for t in new:
            seen_texts.add(t)
            for pat in LEAK_RE:
                if pat in t:
                    leaks.append((pat, t[:90]))
                    break
        n_stops += 1
        # 大步下滚
        for _ in range(4):
            run([HDC, "shell", "uinput", "-T", "-m", "630", "2000",
                 "630", "600", "150"])
        time.sleep(1.2)
    return n_stops, leaks


def main():
    pages = sys.argv[1:] or ["阿比盖尔", "鱼", "家具", "友谊", "传说之鱼",
                             "版本历史", "罐头瓶生产力 - 农耕人", "姜岛", "武器", "任务"]
    report = {}
    for title in pages:
        stops, leaks = sweep_page(title)
        report[title] = {"stops": stops, "leaks": leaks}
        print(f"[{title}] stops={stops} leaks={len(leaks)}", flush=True)
        for pat, t in leaks[:6]:
            print(f"    {pat}  {t}", flush=True)
    (OUT / "leak_sweep.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    total = sum(len(v["leaks"]) for v in report.values())
    print(f"TOTAL leaks: {total}")


if __name__ == "__main__":
    main()
