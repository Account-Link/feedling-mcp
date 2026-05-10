"""
Unit tests for the context_memories selection logic (enclave_app.py).
============================================================================

These cover the pure-function selection algorithm — no enclave or Flask
infrastructure required. The selection is what the agent reads alongside
chat history every time it polls; correctness here directly affects every
chat round.

Run with: pytest tests/test_context_memories.py -v
"""

from __future__ import annotations
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "backend"))

# Pure-function module — zero native deps, imports cleanly anywhere Python runs.
from context_memory_selection import (  # noqa: E402
    char_bigrams as _char_bigrams,
    bigram_jaccard as _bigram_jaccard,
    select_context_memories as _select_context_memories,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def _moment(
    *,
    id: str,
    title: str,
    description: str = "",
    occurred_at: str = "2026-01-01T00:00:00",
    created_at: str = "2026-01-01T00:00:00",
    type: str = "",
) -> dict:
    return {
        "id": id,
        "title": title,
        "description": description,
        "type": type,
        "occurred_at": occurred_at,
        "created_at": created_at,
    }


# ---------------------------------------------------------------------------
# Bigram utilities
# ---------------------------------------------------------------------------

def test_bigrams_empty():
    assert _char_bigrams("") == set()
    assert _char_bigrams("a") == set()  # single char → no bigrams


def test_bigrams_basic():
    assert _char_bigrams("abc") == {"ab", "bc"}


def test_bigrams_chinese():
    # Bigrams over Chinese characters work without tokenization.
    assert _char_bigrams("你好吗") == {"你好", "好吗"}


def test_bigrams_lowercased():
    assert _char_bigrams("ABC") == _char_bigrams("abc")


def test_jaccard_identical():
    g = _char_bigrams("hello world")
    assert _bigram_jaccard(g, g) == 1.0


def test_jaccard_disjoint():
    a = _char_bigrams("abc")
    b = _char_bigrams("xyz")
    assert _bigram_jaccard(a, b) == 0.0


def test_jaccard_partial():
    a = _char_bigrams("abcd")  # {ab, bc, cd}
    b = _char_bigrams("bcde")  # {bc, cd, de}
    # intersection = {bc, cd}, union = {ab, bc, cd, de} → 2/4 = 0.5
    assert _bigram_jaccard(a, b) == 0.5


def test_jaccard_empty_inputs():
    assert _bigram_jaccard(set(), set()) == 0.0
    assert _bigram_jaccard(set(), {"ab"}) == 0.0


# ---------------------------------------------------------------------------
# Selection logic
# ---------------------------------------------------------------------------

def test_select_empty_garden():
    assert _select_context_memories([], "anything") == []
    assert _select_context_memories([], "") == []


def test_select_returns_turning_points_first():
    moments = [
        _moment(id="r1", title="random card 1"),
        _moment(id="t1", title="转折｜你第一次说出真心话",
                occurred_at="2026-03-01T00:00:00"),
        _moment(id="t2", title="转折｜重要的一天",
                occurred_at="2026-04-01T00:00:00"),
    ]
    out = _select_context_memories(moments, "")
    out_ids = [m["id"] for m in out]
    # Both turning points present, newest first
    assert out_ids[:2] == ["t2", "t1"]


def test_select_caps_at_8():
    moments = [_moment(id=f"m{i}", title=f"card {i}") for i in range(20)]
    out = _select_context_memories(moments, "")
    assert len(out) <= 8


def test_select_dedupes_across_buckets():
    # A single card that is both a turning point AND most-recently created
    # should appear once, not twice.
    only = _moment(
        id="only",
        title="转折｜the single card",
        created_at="2027-12-31T00:00:00",  # most recent ever
        occurred_at="2026-01-01T00:00:00",
    )
    out = _select_context_memories([only], "")
    assert [m["id"] for m in out] == ["only"]


def test_select_relevance_uses_user_text():
    # Card whose title overlaps with user query should rank into top picks.
    moments = [
        _moment(id="a", title="random one"),
        _moment(id="b", title="random two"),
        _moment(id="c", title="深夜你说想换工作", description="那次咖啡馆里"),
        _moment(id="d", title="random three"),
        _moment(id="e", title="random four"),
        _moment(id="f", title="random five"),
    ]
    # User just said something about 换工作 — card c should surface
    out = _select_context_memories(moments, "我最近又在想换工作的事")
    assert "c" in [m["id"] for m in out]


def test_select_no_user_text_skips_relevance():
    # When latest_user_text is empty, relevance bucket contributes nothing,
    # output is just turning + recent.
    moments = [
        _moment(id="r1", title="card one",   created_at="2026-01-10T00:00:00"),
        _moment(id="r2", title="card two",   created_at="2026-01-09T00:00:00"),
        _moment(id="r3", title="card three", created_at="2026-01-08T00:00:00"),
    ]
    out = _select_context_memories(moments, "")
    # 0 turning + max 2 recent
    assert len(out) == 2
    assert [m["id"] for m in out] == ["r1", "r2"]


def test_select_orders_recent_by_created_at_desc():
    moments = [
        _moment(id="old",    title="o", created_at="2026-01-01T00:00:00"),
        _moment(id="newer",  title="n", created_at="2026-06-01T00:00:00"),
        _moment(id="newest", title="x", created_at="2026-12-01T00:00:00"),
    ]
    out = _select_context_memories(moments, "")
    # max 2 recent, newest first
    assert [m["id"] for m in out[:2]] == ["newest", "newer"]


def test_select_handles_500_cards_under_budget():
    # Stress: 500 cards, request still completes quickly. Time budget
    # is generous (this asserts < 1 second; in practice << 100 ms).
    import time
    moments = [
        _moment(
            id=f"m{i}",
            title=f"transient title {i}",
            description=f"some description text number {i} " * 5,
            created_at=f"2026-{(i % 12) + 1:02d}-{(i % 28) + 1:02d}T00:00:00",
        )
        for i in range(500)
    ]
    # Sprinkle a few turning points
    moments[100]["title"] = "转折｜special one"
    moments[300]["title"] = "转折｜special two"

    start = time.time()
    out = _select_context_memories(
        moments,
        "looking for something specific in description text",
    )
    elapsed = time.time() - start

    assert len(out) <= 8
    assert elapsed < 1.0, f"selection took {elapsed:.2f}s on 500 cards (budget 1.0s)"


def test_select_caps_turning_points_at_3():
    # 5 turning points should yield only the 3 newest in the turning bucket.
    moments = [
        _moment(id=f"t{i}", title=f"转折｜card {i}",
                occurred_at=f"2026-{i + 1:02d}-01T00:00:00")
        for i in range(5)
    ]
    out = _select_context_memories(moments, "")
    turning_ids = [m["id"] for m in out if m["title"].startswith("转折｜")]
    # Top 3 by occurred_at desc should be t4, t3, t2
    assert turning_ids[:3] == ["t4", "t3", "t2"]
