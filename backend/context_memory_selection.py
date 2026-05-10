"""
context_memories selection — pure helpers, no native deps.
============================================================

Lives outside enclave_app.py so it can be unit-tested without the full
nacl / cryptography stack. enclave_app.py imports from here.

The selection feeds into every /v1/chat/history response: up to 8 plaintext
memory cards the agent reads alongside chat history. Rules:
  · Up to 3 turning-point cards (title prefix `转折｜`), newest first
  · Up to 2 most-recently-created cards
  · Up to 3 cards with highest character-bigram Jaccard overlap against
    the latest user message
  · Dedupe by id, cap total at 8

Bigrams (no tokenization) so zh + en + mixed all work without language
deps. Acceptable up to ~5000 cards/user; beyond that, swap in vector
search.
"""

from __future__ import annotations


def char_bigrams(s: str) -> set:
    """Lowercase character bigrams. Empty/single-char input → empty set."""
    if not s:
        return set()
    s = s.lower()
    if len(s) < 2:
        return set()
    return {s[i:i + 2] for i in range(len(s) - 1)}


def bigram_jaccard(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    inter = len(a & b)
    if inter == 0:
        return 0.0
    return inter / len(a | b)


def select_context_memories(
    moments: list[dict],
    latest_user_text: str,
    cap: int = 8,
) -> list[dict]:
    """Pick up to `cap` memory cards: turning points + recent + relevance.

    `moments` are pre-decrypted dicts with at least these keys:
      id, title, description, occurred_at, created_at
    """
    if not moments:
        return []

    chosen_ids: set = set()
    out: list[dict] = []

    # Bucket 1 — turning points by occurred_at desc, max 3
    turning = sorted(
        [m for m in moments if (m.get("title") or "").startswith("转折｜")],
        key=lambda m: m.get("occurred_at") or "",
        reverse=True,
    )[:3]
    for m in turning:
        if m["id"] not in chosen_ids:
            out.append(m)
            chosen_ids.add(m["id"])

    # Bucket 2 — most-recently-created (skip already-chosen), max 2
    recent_pool = [m for m in moments if m["id"] not in chosen_ids]
    recent = sorted(
        recent_pool,
        key=lambda m: m.get("created_at") or "",
        reverse=True,
    )[:2]
    for m in recent:
        if m["id"] not in chosen_ids:
            out.append(m)
            chosen_ids.add(m["id"])

    # Bucket 3 — relevance to latest user message, max 3
    if latest_user_text:
        q_grams = char_bigrams(latest_user_text)
        if q_grams:
            scored = []
            for m in moments:
                if m["id"] in chosen_ids:
                    continue
                hay = (m.get("title") or "") + " " + (m.get("description") or "")
                score = bigram_jaccard(q_grams, char_bigrams(hay))
                if score > 0:
                    scored.append((score, m))
            scored.sort(key=lambda x: -x[0])
            for _, m in scored[:3]:
                if m["id"] not in chosen_ids:
                    out.append(m)
                    chosen_ids.add(m["id"])

    return out[:cap]
