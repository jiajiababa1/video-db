#!/usr/bin/env python3
"""站点静态检查: HTML 内嵌 JS 语法 + scraper Python 语法 + JSON 合法性。
用法: python3 tools/check_site.py (在仓库根目录运行; 需要 node 在 PATH 中)
任一检查失败以非零码退出, 供 GitHub Actions 拦截坏提交。"""
import json
import py_compile
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
failures = []


def check_html_js(name):
    p = ROOT / name
    if not p.exists():
        return
    html = p.read_text(encoding="utf-8")
    blocks = re.findall(r"<script(?![^>]*src=)[^>]*>(.*?)</script>", html, re.S)
    for i, code in enumerate(blocks):
        if not code.strip():
            continue
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as f:
            f.write(code)
            tmp = f.name
        r = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
        if r.returncode != 0:
            failures.append(f"{name} script#{i}: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'syntax error'}")
    print(f"{name}: {len(blocks)} script blocks checked")


def check_python():
    files = sorted((ROOT / "scraper").glob("*.py"))
    for f in files:
        try:
            py_compile.compile(str(f), doraise=True)
        except py_compile.PyCompileError as e:
            failures.append(f"{f.name}: {e}")
    print(f"scraper: {len(files)} py files checked")


def check_json():
    for name in ("manifest.json", "manifest-2048.json"):
        p = ROOT / name
        if not p.exists():
            continue
        try:
            json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            failures.append(f"{name}: {e}")
    print("json manifests checked")


if __name__ == "__main__":
    check_html_js("index.html")
    check_html_js("watch.html")
    check_python()
    check_json()
    if failures:
        print("\n❌ 检查失败:")
        for f_ in failures:
            print(" -", f_)
        sys.exit(1)
    print("✅ 全部检查通过")
