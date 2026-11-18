"""Score report. A fine-tune is never claimed."""

from __future__ import annotations

from maia_harness.agent import RunResult
from maia_harness.distill import redact
from maia_harness.prompts import Harness
from maia_harness.tasks import SUBTASKS

_COLUMNS = [task.id for task in SUBTASKS]


def _fence(text: str) -> str:
    marker = "```"
    while marker in text:
        marker += "`"
    return f"{marker}text\n{text}\n{marker}"


def _row(name: str, result: RunResult | None, note: str = "") -> str:
    if result is None or len(result.scores) != len(_COLUMNS):
        blanks = " | ".join([""] * len(_COLUMNS))
        return f"| {name} | {note or 'not run'} | {blanks} |"
    cells = " | ".join(str(score) for score in result.scores)
    return f"| {name} | {result.mean:.3f} | {cells} |"


def _excerpt(answer: str) -> str:
    flat = " ".join(answer.split())
    if len(flat) > 160:
        return flat[:157] + "..."
    return flat or "(empty)"


def render_report(
    *,
    model: str,
    selection: list[RunResult],
    child: RunResult | None,
    child_note: str,
    optimized: RunResult | None,
    distill_scores: RunResult | None,
    dataset_path: str,
    dataset_calls: int | None,
    swap_ok: bool | None,
    error: str | None,
    execution_note: str,
    task_max_tokens: int,
) -> str:
    by_name = {result.harness.name: result for result in selection}
    executed = (
        error is None
        and swap_ok is True
        and distill_scores is not None
        and dataset_calls is not None
        and dataset_calls > 0
    )
    winner: Harness | None = optimized.harness if optimized is not None else None
    lines = [
        "# Maia memory harness distillation",
        "",
        f"Distillation executed: {'yes' if executed else 'no'}",
        "",
        "A fine-tune did not run. The runner writes the swapped-prompt dataset "
        "and this report. No LoRA training is part of the command.",
        "",
        f"Model: `{model}`",
        f"Task max_tokens: {task_max_tokens}",
        "Repeats per harness: 1",
        "",
        "Pipeline: one pass over the generic harness and the Summary, Retrieval, "
        "Skill, and Hypothesis seeds; one meta revision of the best of those; "
        "keep the better of parent and child; run that harness again and replace "
        "its LOAD and OFFLOAD text with the generic prompts in the logged calls.",
        "",
        "## Scores",
        "",
        "Each subtask is 0 or 1 from a string check on the final answer. "
        "Context is cleared after every subtask. `optimized` is the separate "
        "demonstration pass that produced the dataset, not the selection pass.",
        "",
        "| harness | mean | " + " | ".join(_COLUMNS) + " |",
        "| --- | --- | " + " | ".join(["---"] * len(_COLUMNS)) + " |",
    ]
    for name in ("generic", "summary", "retrieval", "skill", "hypothesis"):
        lines.append(_row(name, by_name.get(name)))
    lines.append(_row("meta-1", child))
    opt_label = f"optimized ({winner.name})" if winner is not None else "optimized"
    lines.append(_row(opt_label, distill_scores))
    lines.extend(["", "## Meta revision", "", child_note])
    if optimized is not None and winner is not None:
        lines.extend(
            [
                "",
                f"Optimized harness: `{winner.name}` "
                f"(selection mean {optimized.mean:.3f}).",
                "",
                "### LOAD",
                "",
                _fence(winner.load),
                "",
                "### OFFLOAD",
                "",
                _fence(winner.offload),
            ]
        )
    else:
        lines.extend(
            ["", "Optimized LOAD and OFFLOAD: none. The search did not finish."]
        )
    lines.extend(["", "## Answers", ""])
    shown = list(selection)
    if child is not None:
        shown.append(child)
    if distill_scores is not None:
        shown.append(distill_scores)
    if not shown:
        lines.append("No subtasks were scored.")
    for result in shown:
        label = result.harness.name
        if distill_scores is not None and result is distill_scores:
            label = f"optimized ({result.harness.name})"
        lines.append(f"### {label}")
        lines.append("")
        for trace in result.traces:
            files = ", ".join(trace.files) or "(no files)"
            tools = ", ".join(trace.tools) or "(no tools)"
            lines.append(
                f"- {trace.id}: {trace.score} — {_excerpt(trace.answer)} "
                f"(tools: {tools}; files: {files})"
            )
        lines.append("")
    lines.extend(["## Dataset", ""])
    if executed:
        lines.append(f"- Path: `{dataset_path}`")
        lines.append(f"- Calls: {dataset_calls}")
        lines.append(
            "- Swap check: passed. Generic LOAD and OFFLOAD are the context "
            "prompts. The optimized prompts are absent. Assistant text and tool "
            "calls are the targets; tool results appear only as context."
        )
    else:
        lines.append(f"- Path: `{dataset_path}` was not produced.")
        if swap_ok is False:
            lines.append("- Swap check: failed. The dataset was not kept.")
    if error:
        lines.extend(["", "## Error", "", error])
    lines.extend(
        [
            "",
            "## Execution",
            "",
            execution_note.strip() or "Host note: none.",
            "",
        ]
    )
    return redact("\n".join(lines))
