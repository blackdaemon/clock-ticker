#!/usr/bin/env python3

import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock

import pendulum


MODULE_PATH = Path(__file__).parent.parent / "modules" / "claude_usage.py"
SPEC = importlib.util.spec_from_file_location("claude_usage", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
CLAUDE_USAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLAUDE_USAGE)


def extra_usage(**fields) -> dict:
    return {
        "extra_usage": {
            "is_enabled": True,
            "monthly_limit": 5000,
            "used_credits": 1250,
            "utilization": 25,
            "currency": "USD",
            **fields,
        }
    }


class CreditBalanceTest(unittest.TestCase):
    def test_remaining_allowance_in_major_units(self) -> None:
        self.assertEqual(CLAUDE_USAGE.format_credit_balance(extra_usage()), "37.5")

    def test_no_usage_credits(self) -> None:
        self.assertEqual(CLAUDE_USAGE.format_credit_balance({}), "none")
        self.assertEqual(
            CLAUDE_USAGE.format_credit_balance({"extra_usage": None}), "none"
        )

    def test_disabled_usage_credits(self) -> None:
        self.assertEqual(
            CLAUDE_USAGE.format_credit_balance(extra_usage(is_enabled=False)), "none"
        )

    def test_unlimited_usage_credits(self) -> None:
        self.assertEqual(
            CLAUDE_USAGE.format_credit_balance(extra_usage(monthly_limit=None)),
            "unlimited",
        )

    def test_overspent_balance(self) -> None:
        self.assertEqual(
            CLAUDE_USAGE.format_credit_balance(
                extra_usage(monthly_limit=100, used_credits=225)
            ),
            "-1.2",
        )

    def test_invalid_balance(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid credit balance"):
            CLAUDE_USAGE.format_credit_balance(extra_usage(monthly_limit="unknown"))


class WindowTest(unittest.TestCase):
    def setUp(self) -> None:
        patcher = mock.patch.object(
            pendulum, "now", return_value=pendulum.datetime(2026, 10, 31, 1, 0, 0)
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_short_window_shows_local_reset_time(self) -> None:
        limits = [{"kind": "session", "percent": 55.6, "resets_at": "2026-10-31T02:30:00+00:00"}]
        expected = (
            pendulum.parse("2026-10-31T02:30:00+00:00")
            .in_timezone(pendulum.local_timezone())
            .format("HH:mm")
        )
        self.assertEqual(
            CLAUDE_USAGE.format_window(limits, CLAUDE_USAGE.SHORT_WINDOW, show_time=True),
            ("5h", 44, f"1.5h ({expected})"),
        )

    def test_long_window_shows_remaining_only(self) -> None:
        limits = [{"kind": "weekly_all", "percent": 8, "resets_at": "2026-11-04T04:00:00+00:00"}]
        self.assertEqual(
            CLAUDE_USAGE.format_window(limits, CLAUDE_USAGE.LONG_WINDOW, show_time=False),
            ("7d", 92, "4d3h"),
        )

    def test_missing_and_elapsed_reset_times(self) -> None:
        self.assertEqual(CLAUDE_USAGE.format_reset_time(None, show_time=True), "unknown")
        self.assertEqual(
            CLAUDE_USAGE.format_reset_time("2026-10-30T00:00:00+00:00", show_time=False),
            "0m",
        )

    def test_missing_window(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "no weekly_all usage window"):
            CLAUDE_USAGE.format_window([], CLAUDE_USAGE.LONG_WINDOW, show_time=False)


class UsageReportTest(unittest.TestCase):
    def run_with_output(self, stdout: str) -> dict:
        completed = subprocess.CompletedProcess([], 0, stdout=stdout)
        with mock.patch.object(CLAUDE_USAGE, "find_claude", return_value="claude"), \
                mock.patch.object(subprocess, "run", return_value=completed):
            return CLAUDE_USAGE.request_rate_limits()

    def test_report_found_among_stream_messages(self) -> None:
        rate_limits = {"limits": [], "extra_usage": None}
        stdout = "\n".join(
            json.dumps(message)
            for message in (
                {"type": "system", "subtype": "init"},
                {"type": "assistant", "usage_report": {"rate_limits": rate_limits}},
                {"type": "result"},
            )
        )
        self.assertEqual(self.run_with_output(stdout), rate_limits)

    def test_missing_report(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "without a usage report"):
            self.run_with_output(json.dumps({"type": "result"}))

    def test_unavailable_rate_limits(self) -> None:
        stdout = json.dumps({"usage_report": {"rate_limits": None}})
        with self.assertRaisesRegex(RuntimeError, "no subscription rate limits"):
            self.run_with_output(stdout)

    def test_malformed_output(self) -> None:
        with self.assertRaises(ValueError):
            self.run_with_output("not json")


if __name__ == "__main__":
    unittest.main()
