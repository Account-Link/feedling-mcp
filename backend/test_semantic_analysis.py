"""Unit tests for backend/semantic_analysis.py.

Same test cases the Swift port needs to pass. Keep this suite and the
Swift equivalent (Phase 1E) in lockstep.
"""
import unittest
from semantic_analysis import analyze, contains_any


class TestContainsAny(unittest.TestCase):
    def test_case_insensitive_match(self):
        self.assertTrue(contains_any("Cart full", ("cart",)))

    def test_none_text_treated_as_empty(self):
        self.assertFalse(contains_any(None, ("cart",)))

    def test_no_match_returns_false(self):
        self.assertFalse(contains_any("nothing here", ("cart",)))

    def test_multiple_keywords_any_hit_wins(self):
        self.assertTrue(contains_any("tiny review", ("review", "foo")))


class TestAnalyze(unittest.TestCase):
    def test_ecommerce_choice_paralysis(self):
        r = analyze("com.taobao", "购物车 加入购物车 评价")
        self.assertEqual(r["semantic_scene"], "ecommerce_choice_paralysis")
        self.assertEqual(r["semantic_strength"], "strong")
        self.assertAlmostEqual(r["confidence"], 0.86)
        self.assertEqual(len(r["suggested_openers"]), 3)

    def test_ecommerce_app_from_ocr_text(self):
        """OCR text alone is enough to detect ecommerce context."""
        r = analyze("browser", "Amazon Cart — review sizes")
        self.assertEqual(r["semantic_scene"], "ecommerce_choice_paralysis")

    def test_social_chat_hesitation(self):
        r = analyze("com.tencent.wechat", "草稿：怎么回 …撤回")
        self.assertEqual(r["semantic_scene"], "social_chat_hesitation")
        self.assertAlmostEqual(r["confidence"], 0.83)

    def test_chat_app_keyword_from_ocr(self):
        r = analyze("unknown", "Telegram typing… sorry unsent")
        self.assertEqual(r["semantic_scene"], "social_chat_hesitation")

    def test_ambiguous_fallback(self):
        r = analyze("com.apple.mobilesafari", "today's weather in tokyo")
        self.assertEqual(r["semantic_scene"], "ambiguous_context")
        self.assertEqual(r["semantic_strength"], "weak")

    def test_missing_compare_word_in_ecom_app_falls_through(self):
        """Being in an ecom app alone shouldn't trigger strong — needs a
        compare-word too."""
        r = analyze("com.taobao", "just browsing")
        self.assertEqual(r["semantic_scene"], "ambiguous_context")

    def test_returned_dict_shape_is_stable(self):
        required = {"semantic_scene", "task_intent", "friction_point",
                    "semantic_strength", "confidence", "suggested_openers"}
        for args in [("taobao", "购物车 评价"),
                     ("wechat", "撤回 怎么回"),
                     ("", "")]:
            with self.subTest(args=args):
                r = analyze(*args)
                self.assertTrue(required.issubset(r.keys()))
                self.assertIsInstance(r["suggested_openers"], list)


if __name__ == "__main__":
    unittest.main()
