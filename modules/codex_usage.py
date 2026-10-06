#!/usr/bin/env python3

import json
from decimal import Decimal, InvalidOperation
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import time

import pendulum
from babel.numbers import format_decimal
from pendulum import Interval


def find_codex() -> str:
    codex = shutil.which("codex")
    if codex is not None:
        return codex

    candidates = Path.home().glob(
        ".cache/JetBrains/*/acp-agents/codex-acp/*/node_modules/.bin/codex"
    )
    executables = [
        path
        for path in candidates
        if path.is_file() and path.stat().st_mode & 0o111
    ]
    if executables:
        return str(max(executables, key=lambda path: path.stat().st_mtime))

    raise RuntimeError(
        "codex executable not found in PATH or the JetBrains Codex installation"
    )


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


def format_reset_time(timestamp: int) -> str:
    if timestamp <= 0:
        return "unknown"

    reset_time: pendulum.DateTime = pendulum.from_timestamp(timestamp)
    remaining: pendulum.Duration = reset_time - pendulum.now(reset_time.timezone)
    if remaining.total_seconds() < 0:
        remaining = pendulum.duration()

    return format_duration(
        remaining
    )


def format_window_duration(minutes: int) -> str:
    if minutes <= 0:
        raise ValueError("Codex returned an invalid usage window duration")
    if minutes % (24 * 60) == 0:
        return f"{minutes // (24 * 60)}d"
    if minutes % 60 == 0:
        return f"{minutes // 60}h"
    return f"{minutes}m"


def format_window(window: dict) -> tuple[str, int, str]:
    duration = format_window_duration(window["windowDurationMins"])
    remaining = max(0, min(100, 100 - round(window["usedPercent"])))
    resets_at = window.get("resetsAt") or 0
    return duration, remaining, format_reset_time(resets_at)


def format_credit_balance(rate_limits: dict) -> str:
    credits = rate_limits.get("credits")
    if not isinstance(credits, dict) or not credits.get("hasCredits"):
        return "none"
    if credits.get("unlimited"):
        return "unlimited"

    try:
        balance = Decimal(str(credits["balance"]))
    except (InvalidOperation, KeyError):
        raise ValueError("Codex returned an invalid credit balance") from None

    return format(balance, ".1f")


def request_rate_limits() -> dict:
    codex = find_codex()

    requests = (
        {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "clock-ticker",
                    "title": "Clock Ticker",
                    "version": "1",
                }
            },
        },
        {"id": 2, "method": "account/rateLimits/read", "params": None},
    )
    process = subprocess.Popen(
        [codex, "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert process.stdin is not None
    assert process.stdout is not None

    try:
        for request in requests:
            process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()

        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + 30

        while time.monotonic() < deadline:
            events = selector.select(deadline - time.monotonic())
            if not events:
                break

            line = process.stdout.readline()
            if not line:
                break
            message = json.loads(line)
            if message.get("id") != 2:
                continue
            if "error" in message:
                raise RuntimeError(str(message["error"]))
            return message["result"]["rateLimits"]

        raise RuntimeError("timed out waiting for Codex rate limits")
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main() -> None:
    rate_limits = request_rate_limits()
    primary = rate_limits.get("primary")
    secondary = rate_limits.get("secondary")
    if primary is None or secondary is None:
        raise RuntimeError("Codex returned fewer than two usage windows")

    fields = (
        *format_window(primary),
        *format_window(secondary),
        format_credit_balance(rate_limits),
    )
    print("\t".join(map(str, fields)), end="")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Unable to read Codex usage: {error}", file=sys.stderr)
        raise SystemExit(1)
