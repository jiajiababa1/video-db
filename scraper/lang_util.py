#!/usr/bin/env python3
"""标题语言判定 (零依赖, 微秒级) — 给爬虫做中文优先排序/过滤用。

为什么不用 langdetect / AI:
  - 标题大多是几字到几十字的推文短文本, 重型模型慢且要联网/配额;
  - 中日区分其实靠文字系统就够了: 日文几乎必含假名, 中文不含假名;
    再叠加简体专用字 / 常用虚词, 短文本准确率足够做"排序"用途。
判定结果只用于优先级排序和作者池筛选, 不做硬删除, 误判不会丢数据。

分类:
  zh      — 汉字为主, 无假名 (或假名极少), 含中文信号
  ja      — 含假名且占一定比例 (日文推文的常态)
  other   — 拉丁字母为主等其他语言
  unknown — 无有效文本 / 纯符号数字 / 汉字太少无法判定
"""
import re

_HAN = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf]")
_KANA = re.compile(r"[\u3040-\u30ff\u31f0-\u31ff]")  # 平假名+片假名
_LATIN = re.compile(r"[A-Za-z]")

# 简体专用字 (繁体里基本不这样写): 的国这说没过还现让给们么着进远运达
_SIMPLIFIED = set("的国这说没过还现让给们么着进远运达对开关门问间阳阴队长乐车马龙书画")
# 中文高频虚词/结构 (短标题里出现任意一个就是强中文信号)
_ZH_WORDS = ("的", "了", "是", "我", "在", "和", "不", "都", "也", "就",
             "被", "把", "让", "跟", "给", "到", "去", "看", "想", "要")


def _counts(text):
    t = text or ""
    return (len(_HAN.findall(t)), len(_KANA.findall(t)), len(_LATIN.findall(t)))


def classify_title(text):
    """返回 (lang, score)。score 越高越像中文 (zh 排序用, 0..1 左右)。"""
    t = (text or "").strip()
    if not t:
        return "unknown", 0.0
    han, kana, latin = _counts(t)
    total = han + kana + latin
    if total == 0:
        return "unknown", 0.0
    # 日文: 有假名。中文网络文本偶尔借一个 の, 所以假名 >=2 或假名多于汉字才判日文
    if kana >= 2 or (kana >= 1 and kana > han):
        return "ja", 0.05
    if han == 0:
        return "other", 0.0
    han_ratio = han / total
    if han < 2 and han_ratio < 0.5:
        return "unknown", 0.1
    score = han_ratio
    chars = set(t)
    if chars & _SIMPLIFIED:
        score += 0.25                      # 简体专用字是强信号
    if any(w in t for w in _ZH_WORDS):
        score += 0.15                      # 中文虚词
    if kana == 1:
        score -= 0.2                       # 单个假名 (多半是 の) 轻微扣分, 不翻盘
    return "zh", min(score, 1.0)


def cn_score(text):
    """中文优先分: zh 按置信度, unknown 给中低分 (无标题视频不该被埋没), 其余垫底。"""
    lang, s = classify_title(text)
    if lang == "zh":
        return 0.5 + 0.5 * s
    if lang == "unknown":
        return 0.35
    if lang == "ja":
        return 0.1
    return 0.15


def is_chinese(text):
    return classify_title(text)[0] == "zh"
