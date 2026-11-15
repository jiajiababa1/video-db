"""
规则化抓源引擎 (v1, 2026-11-16)
================================================================
思路学 Kazumi / CloudStream: 源站抓取 = 一份规则 (JSON), 不再是写死的代码。
一条规则 = 列表页 URL 模板 + 卡片切分串 + 每字段一条正则 + 详情页字段正则,
正好是现有 RE_HX_* 正则集的配置化形态。

规则热下发: 运行时先拉 GitHub Pages 上的 updates/rules.json —— 改规则只要
提交那个文件, 下一轮抓取自动生效, 不用动代码; 拉不到就用仓库内
scraper/rules.json 兜底。

与现有通道的关系: main.py 的 crawl_hsex 等专属爬虫不受影响, 继续跑;
规则引擎是并行通道, 新源优先用规则加 (老源 hsex 的规则与专属爬虫等价,
两边都开也不会重复入库 —— upsert 按 video_id 合并)。
"""
import html as htmlmod
import json
import os
import re
import time
from urllib.parse import unquote, urljoin

import httpx

try:
    from curl_cffi import requests as creq  # 浏览器 TLS 指纹 (与 main.py 同策略)
except Exception:
    creq = None

REMOTE_RULES_URL = "https://jiajiababa1.github.io/video-db/updates/rules.json"
LOCAL_RULES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rules.json")
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"


def _validate(data):
    return isinstance(data, dict) and isinstance(data.get("sources"), list)


def load_rules(log=print):
    """先远程后本地; 返回 (rules_dict, origin)"""
    try:
        r = httpx.get(REMOTE_RULES_URL, timeout=12, follow_redirects=True,
                      headers={"User-Agent": UA})
        if r.status_code == 200:
            data = r.json()
            if _validate(data):
                log(f"[rules] 已加载远程规则 v{data.get('version')} ({REMOTE_RULES_URL})")
                return data, "remote"
        log(f"[rules] 远程规则不可用 (HTTP {r.status_code}), 用本地兜底")
    except Exception as e:
        log(f"[rules] 远程规则拉取失败 ({str(e)[:60]}), 用本地兜底")
    try:
        with open(LOCAL_RULES, encoding="utf-8") as f:
            data = json.load(f)
        if _validate(data):
            log(f"[rules] 已加载本地规则 v{data.get('version')}")
            return data, "local"
    except Exception as e:
        log(f"[rules] 本地规则也读不到: {e}")
    return {"version": 0, "sources": []}, "none"


def _extract(spec, text):
    """按字段规格抽值: regex (或 regex_any 多个兜底), 默认取第 1 组, group 可指定"""
    if not spec or not text:
        return ""
    pats = spec.get("regex_any") or [spec.get("regex", "")]
    group = spec.get("group", 1)
    for pat in pats:
        if not pat:
            continue
        m = re.search(pat, text)
        if m:
            try:
                val = m.group(group) or ""
            except Exception:
                val = ""
            val = htmlmod.unescape(val).strip()
            if spec.get("urldecode"):
                val = unquote(val).strip()
            return val
    return ""


def parse_list(rule, html_text, page_url):
    """按规则解析列表页 -> 与 sb_save / parse_hsex_list 同构的行 dict 列表"""
    lst = rule.get("list") or {}
    fields = lst.get("fields") or {}
    split = lst.get("card_split", "")
    if not html_text or not split:
        return []
    base = rule.get("base", "")
    out = []
    for chunk in html_text.split(split)[1:]:
        rid = _extract(fields.get("id"), chunk)
        if not rid:
            continue
        row = {
            "video_id": rule.get("prefix", "") + rid,
            "title": _extract(fields.get("title"), chunk),
            "thumbnail": _extract(fields.get("thumb"), chunk),
            "author": _extract(fields.get("author"), chunk).lstrip(" "),
            "url": (lst.get("detail_url") or "{base}/video-{id}.htm")
                   .replace("{base}", base).replace("{id}", rid),
            "source_page": page_url,
            "source_section": rule.get("section", rule.get("name", "")),
            "duration": _extract(fields.get("duration"), chunk),
            "views": _extract(fields.get("views"), chunk),
            "mp4_url": "",
            "has_mp4": False,
            "needs_rescrape": False,
            "_rule_id": rid,
        }
        if not row["thumbnail"] and lst.get("thumb_fallback"):
            row["thumbnail"] = lst["thumb_fallback"].replace("{id}", rid).replace("{base}", base)
        if row["thumbnail"] and not row["thumbnail"].startswith("http"):
            row["thumbnail"] = urljoin(base, row["thumbnail"])
        out.append(row)
    return out


def parse_detail(rule, html_text):
    """按规则解析详情页 -> {media, title, author, duration}"""
    fields = (rule.get("detail") or {}).get("fields") or {}
    return {k: _extract(fields.get(k), html_text)
            for k in ("media", "title", "author", "duration")}


def _get_text(client, url):
    """httpx 直连; 失败换 curl_cffi 伪装指纹; 429 等 15 秒重试一次 (站点限速和解)"""
    try:
        r = client.get(url)
        if r.status_code == 200:
            return r.text
    except Exception:
        pass
    if creq is not None:
        try:
            rr = creq.get(url, headers={"User-Agent": UA}, timeout=30, impersonate="chrome")
            if rr.status_code == 429:
                time.sleep(15)
                rr = creq.get(url, headers={"User-Agent": UA}, timeout=30, impersonate="chrome")
            if rr.status_code == 200:
                return rr.text
        except Exception:
            pass
    return ""


def run_source(rule, save_fn, existing_ids, log=print, deadline=None):
    """跑一个规则源: 列表页直收全部卡片 + 只给新条目抓详情补媒体直链 (有上限)。
    返回 {found, saved, details, errors}"""
    stats = {"found": 0, "saved": 0, "details": 0, "errors": []}
    base = rule.get("base", "")
    lst = rule.get("list") or {}
    pages = int(lst.get("pages", 1) or 1)
    cap = int(rule.get("detail_cap", 60) or 60)
    interval = float(rule.get("detail_interval", 1.0) or 0)
    client = httpx.Client(timeout=30, headers={"User-Agent": UA}, follow_redirects=True)
    rows = []
    try:
        for page in range(1, pages + 1):
            if deadline and time.time() > deadline:
                break
            url = (lst.get("url") or "").replace("{base}", base).replace("{page}", str(page))
            text = _get_text(client, url)
            if not text:
                stats["errors"].append(f"{rule.get('name')}: 列表页 {page} 抓不到")
                continue
            got = parse_list(rule, text, url)
            stats["found"] += len(got)
            rows.extend(got)
        for row in rows:
            if stats["details"] >= cap:
                break
            if row["video_id"] in existing_ids:
                continue
            if deadline and time.time() > deadline:
                break
            text = _get_text(client, row["url"])
            if interval:
                time.sleep(interval)
            if not text:
                continue
            det = parse_detail(rule, text)
            stats["details"] += 1
            if det.get("media"):
                row["mp4_url"] = det["media"]
                row["has_mp4"] = True
            if det.get("title") and not row["title"]:
                row["title"] = det["title"]
            if det.get("author") and not row["author"]:
                row["author"] = det["author"]
        for row in rows:
            row.pop("_rule_id", None)
        if rows:
            save_fn(rows)
            stats["saved"] = len(rows)
    finally:
        client.close()
    return stats
