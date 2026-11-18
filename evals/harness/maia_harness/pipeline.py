"""One seed pass, one meta revision, then the swapped demonstration run."""

from __future__ import annotations

import json
import re
import shutil
import sys
import traceback
from pathlib import Path
from typing import Any

from maia_harness.agent import Budget, BudgetError, ChatClient, RunResult, run_stream
from maia_harness.client import ApiError
from maia_harness.distill import (
    CallLog,
    DistillError,
    assert_swapped,
    scan_secret,
    to_record,
    write_jsonl,
)
from maia_harness.memory import Memory
from maia_harness.prompts import FACT_WORDS, GENERIC, POOL, TIE_BIAS, Harness
from maia_harness.report import render_report

META_SYSTEM = (
    "You are the meta agent in a self-improving memory loop. "
    "You revise two prompts, LOAD and OFFLOAD, for a task agent that remembers "
    "one person's life in a directory of files. The conversation is cleared after "
    "every subtask. Tools are list_memory, read_memory, write_memory, and edit_memory. "
    "Return one JSON object and nothing else, with keys load and offload. "
    "Do not put a specific person's name, place, drink, or clock time in the prompts."
)

_MIN_PROMPT = 60
_MAX_PROMPT = 2000


def select(results: list[RunResult]) -> RunResult:
    def key(result: RunResult) -> tuple[float, int, int]:
        late = sum(result.scores[-2:])
        return (result.mean, late, TIE_BIAS.get(result.harness.name, -1))

    return max(results, key=key)


def keep_child(parent: RunResult, child: RunResult) -> bool:
    parent_key = (parent.mean, sum(parent.scores[-2:]))
    child_key = (child.mean, sum(child.scores[-2:]))
    return child_key > parent_key


def same_text(parent: Harness, child: Harness) -> bool:
    return (
        parent.load.strip() == child.load.strip()
        and parent.offload.strip() == child.offload.strip()
    )


def parse_revision(text: str) -> Harness | None:
    payload = _json_object(text)
    if payload is None:
        return None
    load = payload.get("load")
    offload = payload.get("offload")
    if not isinstance(load, str) or not isinstance(offload, str):
        return None
    load = load.strip()
    offload = offload.strip()
    if not _acceptable(load) or not _acceptable(offload):
        return None
    if load == offload:
        return None
    return Harness("meta-1", load, offload)


def _acceptable(text: str) -> bool:
    if not _MIN_PROMPT <= len(text) <= _MAX_PROMPT:
        return False
    if any(ord(ch) < 32 and ch not in "\n\t" for ch in text):
        return False
    folded = text.lower()
    return not any(
        re.search(rf"\b{re.escape(word)}\b", folded) is not None for word in FACT_WORDS
    )


def _json_object(text: str) -> dict[str, Any] | None:
    stripped = text.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].startswith("```"):
            lines = lines[:-1]
        stripped = "\n".join(lines).strip()
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError:
        value = None
    if isinstance(value, dict):
        return value
    start = stripped.find("{")
    end = stripped.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        value = json.loads(stripped[start : end + 1])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def summarize(result: RunResult) -> str:
    lines = [
        f"mean={result.mean:.3f}",
        "scores=" + ",".join(str(score) for score in result.scores),
    ]
    for trace in result.traces:
        answer = " ".join(trace.answer.split())[:240]
        tools = ", ".join(trace.tools)[:300] or "(no tools)"
        files = ", ".join(trace.files) or "(no files)"
        lines.append(
            f"- {trace.id} score={trace.score} tools={tools} files={files} answer={answer}"
        )
    last = result.traces[-1].files if result.traces else {}
    lines.append("Final memory files:")
    if not last:
        lines.append("(empty)")
    for path, text in list(last.items())[:8]:
        excerpt = " ".join(text.split())[:280]
        lines.append(f"### {path}\n{excerpt}")
    summary = "\n".join(lines)
    if len(summary) > 12_000:
        return summary[:12_000] + "\n...[truncated]"
    return summary


def revise(client: ChatClient, parent: RunResult) -> Harness | None:
    user = (
        f"Current harness: {parent.harness.name}\n"
        f"Selection mean: {parent.mean:.3f}\n\n"
        "LOAD:\n"
        f"{parent.harness.load}\n\n"
        "OFFLOAD:\n"
        f"{parent.harness.offload}\n\n"
        "Trace:\n"
        f"{summarize(parent)}\n\n"
        "Rewrite LOAD and OFFLOAD so later subtasks can recover corrected "
        "facts and plans from files after the context is cleared. Keep both "
        "prompts reusable. Do not name the person from the trace."
    )
    assistant = client.complete(
        [
            {"role": "system", "content": META_SYSTEM},
            {"role": "user", "content": user},
        ],
        tool_choice="none",
        max_tokens=min(1500, max(getattr(client, "max_tokens", 1024), 1024)),
    )
    return parse_revision(assistant.get("content") or "")


def _memory(out_dir: Path, name: str) -> Memory:
    root = out_dir / "runs" / name / "memory"
    if root.exists():
        shutil.rmtree(root)
    return Memory(root)


def _log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def run_pipeline(
    client: ChatClient,
    out_dir: Path,
    *,
    budget_s: float = 6000,
    execution_note: str = "",
    task_max_tokens: int = 640,
) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    budget = Budget(budget_s)
    selection: list[RunResult] = []
    child: RunResult | None = None
    child_note = "Meta revision did not run."
    optimized: RunResult | None = None
    distill_scores: RunResult | None = None
    dataset_calls: int | None = None
    swap_ok: bool | None = None
    error: str | None = None
    secret = getattr(client, "api_key", "") or ""
    dataset_path = out_dir / "distill.jsonl"
    try:
        for harness in POOL:
            _log(f"evaluating {harness.name}")
            selection.append(
                run_stream(
                    client,
                    harness,
                    _memory(out_dir, harness.name),
                    record=None,
                    budget=budget,
                    log=_log,
                )
            )
        parent = select(selection)
        _log(f"parent {parent.harness.name} mean={parent.mean:.3f}")
        revised = revise(client, parent)
        if revised is None:
            child_note = (
                "Meta revision was not evaluated. The reply was not a usable "
                "pair of prompts, or it named a fact from the trace."
            )
            optimized = parent
        elif same_text(parent.harness, revised):
            child_note = "Meta revision was not evaluated. The reply repeated the parent prompts."
            optimized = parent
        else:
            _log("evaluating meta-1")
            child = run_stream(
                client,
                revised,
                _memory(out_dir, "meta-1"),
                record=None,
                budget=budget,
                log=_log,
            )
            if keep_child(parent, child):
                optimized = child
                child_note = (
                    f"Kept meta-1 (mean {child.mean:.3f}) over parent "
                    f"{parent.harness.name} (mean {parent.mean:.3f})."
                )
            else:
                optimized = parent
                child_note = (
                    f"Kept parent {parent.harness.name} (mean {parent.mean:.3f}) "
                    f"over meta-1 (mean {child.mean:.3f})."
                )
        assert optimized is not None
        _log(f"distilling {optimized.harness.name}")
        logs: list[CallLog] = []
        distill_scores = run_stream(
            client,
            optimized.harness,
            _memory(out_dir, "distill"),
            record=logs,
            budget=budget,
            log=_log,
        )
        records = [to_record(log, optimized.harness, GENERIC) for log in logs]
        assert_swapped(records, optimized.harness, GENERIC)
        swap_ok = True
        temporary = dataset_path.with_suffix(".jsonl.tmp")
        write_jsonl(temporary, records)
        scan_secret(temporary, secret)
        temporary.replace(dataset_path)
        dataset_calls = len(records)
        _log(f"wrote {dataset_path} ({dataset_calls} calls)")
    except (ApiError, BudgetError, DistillError) as exc:
        error = str(exc)
        swap_ok = False if isinstance(exc, DistillError) else swap_ok
        _log(error)
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
        _log(error)
        traceback.print_exc()
    if error is None:
        reported_swap = swap_ok
    elif swap_ok is False:
        reported_swap = False
    else:
        reported_swap = None
    report = render_report(
        model=getattr(client, "model", ""),
        selection=selection,
        child=child,
        child_note=child_note,
        optimized=optimized,
        distill_scores=distill_scores,
        dataset_path=str(dataset_path),
        dataset_calls=None if error is not None else dataset_calls,
        swap_ok=reported_swap,
        error=error,
        execution_note=execution_note,
        task_max_tokens=task_max_tokens,
    )
    report_path = out_dir / "report.md"
    temporary_report = out_dir / "report.md.tmp"
    temporary_report.write_text(report, encoding="utf-8")
    try:
        scan_secret(temporary_report, secret)
    except DistillError as exc:
        report_path.write_text(
            "# Maia memory harness distillation\n\n"
            "Distillation executed: no\n\n"
            "The report was discarded because it contained the API key.\n",
            encoding="utf-8",
        )
        _log(str(exc))
        return 1
    temporary_report.replace(report_path)
    return 0 if error is None else 1
