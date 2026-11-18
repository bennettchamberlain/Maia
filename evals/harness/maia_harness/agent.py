"""Task-agent loop: LOAD, subtask, OFFLOAD, then a cleared session."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Protocol

from maia_harness.distill import CallLog
from maia_harness.memory import Memory, MemoryPathError
from maia_harness.prompts import SYSTEM, Harness
from maia_harness.tasks import SUBTASKS

LOAD_ROUNDS = 3
TASK_ROUNDS = 4
OFFLOAD_ROUNDS = 3
_TOOL_CLIP = 8_000

TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "list_memory",
            "description": "List files in the persistent memory directory.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_memory",
            "description": "Read one memory file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Relative path inside the memory directory.",
                    }
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_memory",
            "description": "Create or replace a memory file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "edit_memory",
            "description": "Replace the first exact occurrence of old text in a memory file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "old": {"type": "string"},
                    "new": {"type": "string"},
                },
                "required": ["path", "old", "new"],
            },
        },
    },
]


class BudgetError(Exception):
    pass


class Budget:
    def __init__(self, seconds: float, clock: Any | None = None) -> None:
        import time

        self._time = time if clock is None else clock
        self.deadline = self._time.monotonic() + seconds

    def check(self) -> None:
        if self._time.monotonic() > self.deadline:
            raise BudgetError("time budget exhausted before the run finished")


class ChatClient(Protocol):
    model: str

    def complete(
        self,
        messages: list[dict[str, Any]],
        *,
        tool_choice: str = "auto",
        max_tokens: int | None = None,
    ) -> dict[str, Any]: ...


def for_context(assistant: dict[str, Any]) -> dict[str, Any]:
    message: dict[str, Any] = {
        "role": "assistant",
        "content": assistant.get("content"),
    }
    if assistant.get("tool_calls"):
        message["tool_calls"] = assistant["tool_calls"]
    return message


def dispatch(memory: Memory, name: str, arguments: str) -> str:
    try:
        parsed = json.loads(arguments or "{}")
    except json.JSONDecodeError:
        return "error: arguments must be a JSON object"
    if not isinstance(parsed, dict):
        return "error: arguments must be a JSON object"
    try:
        if name == "list_memory":
            rows = memory.list_files()
            if not rows:
                return "(empty)"
            shown = rows[:40]
            body = "\n".join(f"{rel} ({size} bytes)" for rel, size in shown)
            if len(rows) > len(shown):
                body += f"\n...[{len(rows) - len(shown)} more files]"
            return body
        if name == "read_memory":
            return _clip(memory.read(parsed.get("path")))
        if name == "write_memory":
            rel = memory.write(parsed.get("path"), parsed.get("content"))
            return f"wrote {rel}"
        if name == "edit_memory":
            rel = memory.edit(parsed.get("path"), parsed.get("old"), parsed.get("new"))
            return f"edited {rel}"
        return f"error: unknown tool {name}"
    except MemoryPathError as exc:
        return f"error: {exc}"


def _clip(text: str) -> str:
    if len(text) <= _TOOL_CLIP:
        return text
    return text[:_TOOL_CLIP] + "\n...[truncated]"


def brief_call(name: str, arguments: str) -> str:
    try:
        parsed = json.loads(arguments or "{}")
    except json.JSONDecodeError:
        parsed = {}
    path = parsed.get("path") if isinstance(parsed, dict) else None
    if isinstance(path, str) and path:
        return f"{name}({path})"
    return name


def run_phase(
    client: ChatClient,
    memory: Memory,
    messages: list[dict[str, Any]],
    *,
    subtask_id: str,
    phase: str,
    prompt: str,
    max_rounds: int,
    logs: list[CallLog] | None,
    tools_used: list[str],
    budget: Budget,
) -> str:
    messages.append({"role": "user", "content": prompt})
    for _round in range(max_rounds):
        budget.check()
        assistant = client.complete(messages, tool_choice="auto")
        if logs is not None:
            logs.append(CallLog(subtask_id, phase, _copy(messages), _copy(assistant)))
        messages.append(for_context(assistant))
        calls = assistant.get("tool_calls") or []
        if not isinstance(calls, list) or not calls:
            return _text(assistant)
        for call in calls:
            function = call.get("function") or {}
            name = function.get("name") or ""
            arguments = function.get("arguments") or "{}"
            tools_used.append(brief_call(name, arguments))
            result = dispatch(memory, name, arguments)
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": call.get("id") or "",
                    "content": result,
                }
            )
    messages.append(
        {
            "role": "user",
            "content": "Stop using tools. Reply with your final message only.",
        }
    )
    budget.check()
    assistant = client.complete(messages, tool_choice="none")
    if logs is not None:
        logs.append(CallLog(subtask_id, phase, _copy(messages), _copy(assistant)))
    messages.append(for_context(assistant))
    return _text(assistant)


def _text(assistant: dict[str, Any]) -> str:
    content = assistant.get("content")
    return content if isinstance(content, str) else ""


def _copy(value: Any) -> Any:
    return json.loads(json.dumps(value))


@dataclass
class SubtaskTrace:
    id: str
    score: int
    answer: str
    tools: list[str]
    files: dict[str, str]


@dataclass
class RunResult:
    harness: Harness
    traces: list[SubtaskTrace] = field(default_factory=list)

    @property
    def scores(self) -> list[int]:
        return [trace.score for trace in self.traces]

    @property
    def mean(self) -> float:
        if not self.scores:
            return 0.0
        return sum(self.scores) / len(self.scores)


def run_stream(
    client: ChatClient,
    harness: Harness,
    memory: Memory,
    *,
    record: list[CallLog] | None,
    budget: Budget,
    log: Any | None = None,
) -> RunResult:
    messages: list[dict[str, Any]] = [{"role": "system", "content": SYSTEM}]
    traces: list[SubtaskTrace] = []
    rounds = {"load": LOAD_ROUNDS, "task": TASK_ROUNDS, "offload": OFFLOAD_ROUNDS}
    for index, task in enumerate(SUBTASKS, start=1):
        tools: list[str] = []
        run_phase(
            client,
            memory,
            messages,
            subtask_id=task.id,
            phase="load",
            prompt=harness.load,
            max_rounds=rounds["load"],
            logs=record,
            tools_used=tools,
            budget=budget,
        )
        answer = run_phase(
            client,
            memory,
            messages,
            subtask_id=task.id,
            phase="task",
            prompt=task.prompt,
            max_rounds=rounds["task"],
            logs=record,
            tools_used=tools,
            budget=budget,
        )
        run_phase(
            client,
            memory,
            messages,
            subtask_id=task.id,
            phase="offload",
            prompt=harness.offload,
            max_rounds=rounds["offload"],
            logs=record,
            tools_used=tools,
            budget=budget,
        )
        score = task.score(answer)
        traces.append(
            SubtaskTrace(
                id=task.id,
                score=score,
                answer=(answer or "")[:1500],
                tools=tools[:40],
                files=memory.snapshot(),
            )
        )
        if log is not None:
            done = sum(item.score for item in traces) / len(traces)
            log(
                f"[{harness.name}] {index}/{len(SUBTASKS)} {task.id} "
                f"score={score} mean={done:.3f}"
            )
        messages = [{"role": "system", "content": SYSTEM}]
    return RunResult(harness=harness, traces=traces)
