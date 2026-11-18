"""Swap optimized LOAD and OFFLOAD text back to the generic prompts.

Each recorded model call becomes one JSONL row. ``messages`` is the
context (generic prompts, prior assistant turns, tool results). ``assistant``
is the supervised target. Tool results stay in context and are never the target.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from maia_harness.prompts import Harness

_SECRET = re.compile(
    r"sk-or-[A-Za-z0-9_\-]+|\bibk_[A-Za-z0-9]+\b|(?i:bearer)\s+[A-Za-z0-9._\-]+"
)


class DistillError(Exception):
    pass


@dataclass
class CallLog:
    subtask_id: str
    phase: str
    messages: list[dict[str, Any]]
    assistant: dict[str, Any]


def redact(text: str) -> str:
    return _SECRET.sub("[redacted]", text)


def redact_value(value: Any) -> Any:
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, list):
        return [redact_value(item) for item in value]
    if isinstance(value, dict):
        return {key: redact_value(item) for key, item in value.items()}
    return value


def _swap_text(text: str, pairs: list[tuple[str, str]]) -> str:
    for old, new in pairs:
        if old and old != new:
            text = text.replace(old, new)
    return text


def _swap_value(value: Any, pairs: list[tuple[str, str]]) -> Any:
    if isinstance(value, str):
        stripped = value.lstrip()
        if stripped.startswith(("{", "[")):
            try:
                parsed = json.loads(value)
            except json.JSONDecodeError:
                return _swap_text(value, pairs)
            swapped = _swap_value(parsed, pairs)
            if swapped == parsed:
                return value
            return json.dumps(swapped, ensure_ascii=False, separators=(",", ":"))
        return _swap_text(value, pairs)
    if isinstance(value, list):
        return [_swap_value(item, pairs) for item in value]
    if isinstance(value, dict):
        return {key: _swap_value(item, pairs) for key, item in value.items()}
    return value


def _pairs(optimized: Harness, generic: Harness) -> list[tuple[str, str]]:
    return [
        (optimized.load, generic.load),
        (optimized.offload, generic.offload),
    ]


def to_record(log: CallLog, optimized: Harness, generic: Harness) -> dict[str, Any]:
    pairs = _pairs(optimized, generic)
    assistant = {
        key: value
        for key, value in log.assistant.items()
        if key in {"role", "content", "tool_calls", "reasoning"}
    }
    if assistant.get("role") != "assistant":
        assistant["role"] = "assistant"
    return {
        "subtask": log.subtask_id,
        "phase": log.phase,
        "messages": _swap_value(log.messages, pairs),
        "assistant": _swap_value(assistant, pairs),
    }


def _contains(value: Any, needle: str) -> bool:
    if not needle:
        return False
    if isinstance(value, str):
        return needle in value
    if isinstance(value, list):
        return any(_contains(item, needle) for item in value)
    if isinstance(value, dict):
        return any(_contains(item, needle) for item in value.values())
    return False


def assert_swapped(
    records: list[dict[str, Any]], optimized: Harness, generic: Harness
) -> None:
    if not records:
        raise DistillError("distillation logged no model calls")
    for old in (optimized.load, optimized.offload):
        if old in (generic.load, generic.offload):
            continue
        for record in records:
            if _contains(record["messages"], old) or _contains(
                record["assistant"], old
            ):
                raise DistillError("optimized prompt still present after swap")
    saw_load = saw_offload = False
    for record in records:
        assistant = record["assistant"]
        if assistant.get("role") != "assistant":
            raise DistillError("supervised target is not an assistant message")
        if _contains(record["messages"], generic.load):
            saw_load = True
        if _contains(record["messages"], generic.offload):
            saw_offload = True
    if not saw_load or not saw_offload:
        raise DistillError("generic LOAD and OFFLOAD are missing from the dataset")


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        json.dumps(redact_value(record), ensure_ascii=False, separators=(",", ":"))
        for record in records
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def scan_secret(path: Path, secret: str) -> None:
    if not secret:
        return
    if secret in path.read_text(encoding="utf-8"):
        path.unlink(missing_ok=True)
        raise DistillError("refusing to keep an output file that contains the API key")
