#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import time
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


class UsageFieldsTest(unittest.TestCase):
    def reset_in(self, days: int) -> int:
        return int(time.time()) + days * 86_400 + 60

    def test_free_plan_fixture(self) -> None:
        rate_limits = {
            "limitId": "codex",
            "primary": {
                "usedPercent": 20,
                "windowDurationMins": 43200,
                "resetsAt": self.reset_in(29),
            },
            "secondary": None,
            "credits": {
                "hasCredits": False,
                "unlimited": False,
                "balance": None,
            },
            "planType": "free",
        }
        self.assertEqual(
            CODEX_USAGE.format_usage_fields(rate_limits),
            ("30d", 80, "29d0h", "none", "none", "none", "none"),
        )

    def test_plus_plan_shows_both_windows(self) -> None:
        rate_limits = {
            "primary": {
                "usedPercent": 69,
                "windowDurationMins": 300,
                "resetsAt": int(time.time()) + 900,
            },
            "secondary": {
                "usedPercent": 11,
                "windowDurationMins": 10080,
                "resetsAt": self.reset_in(6),
            },
            "planType": "plus",
        }
        fields = CODEX_USAGE.format_usage_fields(rate_limits)
        self.assertEqual(fields[:2], ("5h", 31))
        self.assertRegex(fields[2], r"^\d+m \(\d\d:\d\d\)$")
        self.assertEqual(fields[3:], ("7d", 89, "6d0h", "none"))

    def test_no_windows(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "no usage windows"):
            CODEX_USAGE.format_usage_fields({"primary": None, "secondary": None})


if __name__ == "__main__":
    unittest.main()
