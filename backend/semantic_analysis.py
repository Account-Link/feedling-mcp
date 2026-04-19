"""
Semantic-first screen classifier.

Interprets (current_app, ocr_summary) into a structured "what is the user
doing right now" signal used by /v1/screen/analyze to decide trigger_basis
and suggested_openers.

## Portability note (for Phase 2)

This module is deliberately stateless, pure-stdlib, and dependency-free so
it can be translated 1:1 to Swift and shipped inside the iOS app. Under
the v2 E2E plan (docs/DESIGN_E2E.md §4 "Indexing compute location"), OCR
text never leaves the phone — classification runs on-device, and only
the resulting `semantic_scene` tag (and a few peer fields) is uploaded
as plaintext metadata.

The Swift port should:
- Take (currentApp: String, ocrSummary: String) -> SemanticResult
- Carry the same keyword tuples (unicode strings, same casing rules)
- Return the same semantic_strength / confidence / suggested_openers
- Mirror the truth table exactly

That way the server-side classifier stays as a reference + tie-breaker
for agents that don't have a recent-enough iOS build to classify
locally.
"""

from __future__ import annotations


# ---------------------------------------------------------------------------
# Keyword sets — update these in lockstep with the Swift port.
# ---------------------------------------------------------------------------

ECOM_APPS: tuple[str, ...] = (
    "taobao", "tmall", "jd", "pinduoduo", "xhs", "red", "amazon", "shop",
)
COMPARE_WORDS: tuple[str, ...] = (
    "加入购物车", "购物车", "比价", "对比", "参数", "评价", "评论", "销量", "券", "优惠", "选哪个", "纠结", "尺码", "颜色",
    "cart", "review", "compare", "coupon", "which one", "size", "color",
)
CHAT_APPS: tuple[str, ...] = (
    "wechat", "telegram", "whatsapp", "messenger", "imessage", "discord", "slack",
)
CHAT_WORDS: tuple[str, ...] = (
    "输入", "正在输入", "撤回", "删了", "草稿", "怎么回", "回什么", "算了", "生气", "误会", "抱歉", "对不起", "别这样", "随便",
    "typing", "draft", "unsent", "sorry", "angry", "misunderstand",
)


# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------


def contains_any(text: str, keywords: tuple[str, ...]) -> bool:
    """Case-insensitive substring match. `text` may be None."""
    t = (text or "").lower()
    return any(k in t for k in keywords)


def analyze(current_app: str, ocr_summary: str) -> dict:
    """Classify a screen snapshot into a semantic result dict.

    Returned fields (stable contract — iOS Swift port must produce the
    identical shape):
      semantic_scene       str   e.g. "ecommerce_choice_paralysis"
      task_intent          str
      friction_point       str
      semantic_strength    str   one of "strong" | "weak"
      confidence           float 0..1
      suggested_openers    list[str]   up to 3 entries
    """
    app = (current_app or "unknown").lower()
    text = (ocr_summary or "").lower()

    if (contains_any(app, ECOM_APPS) or contains_any(text, ECOM_APPS)) and contains_any(text, COMPARE_WORDS):
        return {
            "semantic_scene": "ecommerce_choice_paralysis",
            "task_intent": "compare_then_decide",
            "friction_point": "choice_overload",
            "semantic_strength": "strong",
            "confidence": 0.86,
            "suggested_openers": [
                "你像在 A/B 里卡住了：你更在意省钱，还是少踩雷？",
                "先别全看，我帮你偷懒：差评关键词 + 近30天销量 + 退货评价，三项就够定。",
                "给你一个止损线：再看 5 分钟就选一个，剩下放收藏。",
            ],
        }

    if (contains_any(app, CHAT_APPS) or contains_any(text, CHAT_APPS)) and contains_any(text, CHAT_WORDS):
        return {
            "semantic_scene": "social_chat_hesitation",
            "task_intent": "draft_or_repair_message",
            "friction_point": "hesitation_or_conflict",
            "semantic_strength": "strong",
            "confidence": 0.83,
            "suggested_openers": [
                "这句你更想保住关系，还是讲清立场？我给你两版一句话。",
                "你像在反复删改。先发降温版一句话，别让情绪抬高。",
                "要硬一点还是软一点？我各给一版，10 秒选。",
            ],
        }

    return {
        "semantic_scene": "ambiguous_context",
        "task_intent": "unknown",
        "friction_point": "unclear_state",
        "semantic_strength": "weak",
        "confidence": 0.38,
        "suggested_openers": [
            "我可能看错了，这会儿你是在想事，还是在躲这件事？",
            "我没完全读懂这屏，但感觉你有点绷着。要我陪你理一下吗？",
            "你现在更需要：被提醒一下，还是被安静陪着？",
        ],
    }
