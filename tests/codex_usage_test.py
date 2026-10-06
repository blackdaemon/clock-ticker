#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).parent.parent / "modules" / "codex_usage.py"
SPEC = importlib.util.spec_from_file_location("codex_usage", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
CODEX_USAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CODEX_USAGE)


class CreditBalanceTest(unittest.TestCase):
    def test_live_purchased_balance_fixture(self) -> None:
        rate_limits = {
            "credits": {
                "balance": "2489.0766000000",
                "hasCredits": True,
                "unlimited": False,
            }
        }
        self.assertEqual(
            CODEX_USAGE.format_credit_balance(rate_limits),
            "2489.1",
        )

    def test_no_purchased_credits(self) -> None:
        self.assertEqual(CODEX_USAGE.format_credit_balance({}), "none")

    def test_unlimited_credits(self) -> None:
        rate_limits = {
            "credits": {
                "balance": None,
                "hasCredits": True,
                "unlimited": True,
            }
        }
        self.assertEqual(
            CODEX_USAGE.format_credit_balance(rate_limits),
            "unlimited",
        )

    def test_negative_balance(self) -> None:
        rate_limits = {
            "credits": {
                "balance": "-1.25",
                "hasCredits": True,
                "unlimited": False,
            }
        }
        self.assertEqual(
            CODEX_USAGE.format_credit_balance(rate_limits),
            "-1.2",
        )

    def test_invalid_balance(self) -> None:
        rate_limits = {
            "credits": {
                "balance": "unknown",
                "hasCredits": True,
                "unlimited": False,
            }
        }
        with self.assertRaisesRegex(ValueError, "invalid credit balance"):
            CODEX_USAGE.format_credit_balance(rate_limits)


if __name__ == "__main__":
    unittest.main()
