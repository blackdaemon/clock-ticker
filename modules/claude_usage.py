#!/usr/bin/env python3

from decimal import Decimal, InvalidOperation
import json
from pathlib import Path
import shutil
import subprocess
import sys

import pendulum
from babel.numbers import format_decimal


# usage_report limit kinds and their display labels; the report carries no
# window durations.
SHORT_WINDOW = ("session", "5h")
LONG_WINDOW = ("weekly_all", "7d")


def find_claude() -> str:
    claude = shutil.which("claude")
    if claude is not None:
        return claude

    # A systemd user service may not have these per-user locations in PATH.
    candidates = (
        Path.home() / ".local/bin/claude",
        Path.home() / ".claude/local/claude",
    )
    for path in candidates:
        if path.is_file() and path.stat().st_mode & 0o111:
            return str(path)

    raise RuntimeError("claude executable not found in PATH or the user installation")


def format_duration(duration: pendulum.Duration, locale="en"):
    seconds = abs(duration.total_seconds())
    sign = "-" if duration.total_seconds() < 0 else ""

    if seconds >= 86_400:
        days, remainder = divmod(int(seconds), 86_400)
        hours = remainder // 3_600
        return f"{sign}{days}d{hours}h"

    if seconds >= 3_600:
        hours = round(seconds / 3_600, 1)
        return f"{sign}{format_decimal(hours, locale=locale, decimal_quantization=False)}h"

    minutes = round(seconds / 60)
    return f"{sign}{format_decimal(minutes, locale=locale)}m"


def format_reset_time(resets_at: str | None, show_time: bool) -> str:
    if not resets_at:
        return "unknown"

    reset_time = pendulum.parse(resets_at)
    if not isinstance(reset_time, pendulum.DateTime):
        raise ValueError("Claude returned an invalid usage reset time")

    remaining: pendulum.Duration = reset_time - pendulum.now("UTC")
    if remaining.total_seconds() < 0:
        remaining = pendulum.duration()

    if show_time:
        local_time = reset_time.in_timezone(pendulum.local_timezone()).format("HH:mm")
        return f"{format_duration(remaining)} ({local_time})"
    return format_duration(remaining)


def format_window(
    limits: list[dict], window: tuple[str, str], show_time: bool
) -> tuple[str, int, str]:
    kind, duration = window
    for limit in limits:
        if limit.get("kind") == kind:
            remaining = max(0, min(100, 100 - round(limit["percent"])))
            return (
                duration,
                remaining,
                format_reset_time(limit.get("resets_at"), show_time=show_time),
            )
    raise RuntimeError(f"Claude returned no {kind} usage window")


def format_credit_balance(rate_limits: dict) -> str:
    """Return what is left of the usage-credit monthly limit, in major units."""
    extra_usage = rate_limits.get("extra_usage")
    if not isinstance(extra_usage, dict) or not extra_usage.get("is_enabled"):
        return "none"

    try:
        monthly_limit = extra_usage["monthly_limit"]
        if monthly_limit is None:
            return "unlimited"
        # Amounts are reported in minor currency units (cents for USD).
        balance = (
            Decimal(str(monthly_limit)) - Decimal(str(extra_usage.get("used_credits") or 0))
        ) / 100
    except (InvalidOperation, KeyError):
        raise ValueError("Claude returned an invalid credit balance") from None

    return format(balance, ".1f")


def request_rate_limits() -> dict:
    # /usage is a local command: it makes no model request and costs no tokens.
    # Without --no-session-persistence, every refresh would write a session log
    # and register as Claude activity. The neutral working directory keeps
    # project settings and hooks out of the refresh.
    process = subprocess.run(
        [
            find_claude(),
            "-p",
            "/usage",
            "--no-session-persistence",
            "--output-format",
            "stream-json",
            "--verbose",
            "--tools",
            "",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        encoding="utf-8",
        timeout=30,
        cwd=Path.home(),
    )

    for line in process.stdout.splitlines():
        message = json.loads(line)
        if not isinstance(message, dict) or "usage_report" not in message:
            continue
        rate_limits = message["usage_report"]["rate_limits"]
        if rate_limits is None:
            raise RuntimeError("Claude returned no subscription rate limits")
        return rate_limits

    raise RuntimeError(f"claude exited with {process.returncode} without a usage report")


def main() -> None:
    rate_limits = request_rate_limits()
    limits = rate_limits.get("limits")
    if not limits:
        raise RuntimeError("Claude returned fewer than two usage windows")

    fields = (
        *format_window(limits, SHORT_WINDOW, show_time=True),
        *format_window(limits, LONG_WINDOW, show_time=False),
        format_credit_balance(rate_limits),
    )
    print("\t".join(map(str, fields)), end="")


if __name__ == "__main__":
    try:
        main()
    except (
        KeyError,
        TypeError,
        ValueError,
        RuntimeError,
        OSError,
        subprocess.TimeoutExpired,
    ) as error:
        print(f"Unable to read Claude usage: {error}", file=sys.stderr)
        raise SystemExit(1)
