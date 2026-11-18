#!/usr/bin/env python3
"""Run the Maia memory-harness distillation eval.

One command, from the repo root or anywhere else:

    python3 evals/harness/run.py

Requires OPENROUTER_API_KEY (OPEN_ROUTER_API_KEY is also accepted). Uses
OPENROUTER_MODEL (default anthropic/claude-sonnet-4.5), OPENROUTER_BASE_URL,
and OPENROUTER_MAX_TOKENS. Writes evals/harness/out/report.md and, when the
model run finishes, evals/harness/out/distill.jsonl.

Does not start the Maia API and does not use Gel. A fine-tune is not run.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def _api_key() -> str | None:
    for name in ("OPENROUTER_API_KEY", "OPEN_ROUTER_API_KEY"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return None


def _positive_int(name: str, default: int, cap: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    if value <= 0:
        return default
    return min(value, cap)


def main() -> int:
    key = _api_key()
    if key is None:
        sys.stderr.write("OPENROUTER_API_KEY is not set\n")
        return 1

    from maia_harness.client import OpenRouterClient
    from maia_harness.pipeline import run_pipeline

    root = Path(__file__).resolve().parent
    model = (
        os.environ.get("OPENROUTER_MODEL", "").strip() or "anthropic/claude-sonnet-4.5"
    )
    base = (
        os.environ.get("OPENROUTER_BASE_URL", "").strip()
        or "https://openrouter.ai/api/v1"
    )
    max_tokens = _positive_int("OPENROUTER_MAX_TOKENS", 640, 1500)
    timeout = float(_positive_int("HARNESS_HTTP_TIMEOUT_S", 45, 90))
    budget = float(_positive_int("HARNESS_BUDGET_S", 6000, 7000))
    note = os.environ.get("HARNESS_EXECUTION_NOTE", "")
    client = OpenRouterClient(
        api_key=key,
        model=model,
        base_url=base,
        max_tokens=max_tokens,
        timeout=timeout,
    )
    return run_pipeline(
        client,
        root / "out",
        budget_s=budget,
        execution_note=note,
        task_max_tokens=max_tokens,
    )


if __name__ == "__main__":
    raise SystemExit(main())
