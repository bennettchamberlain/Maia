"""Offline checks for scoring, the file sandbox, and the prompt swap.

python3 evals/harness/test_harness.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from maia_harness.agent import Budget, RunResult, SubtaskTrace, run_stream
from maia_harness.client import normalize_assistant
from maia_harness.distill import CallLog, assert_swapped, redact, to_record, write_jsonl
from maia_harness.memory import Memory, MemoryPathError
from maia_harness.pipeline import keep_child, parse_revision, run_pipeline, select
from maia_harness.prompts import GENERIC, POOL, SUMMARY, Harness
from maia_harness.tasks import SUBTASKS, sister_is_priya

GOLD = {
    "names": "Your name is Mira Solano and your sister is Priya Solano.",
    "preference": "You like the window seat and oat milk.",
    "plan": "The meeting is at 10:00 at the Ferry Building.",
    "correction": "Your sister's corrected full name is Nia Solano.",
    "recall-correction": "Your sister is Nia Solano. Priya Solano is your cousin.",
    "recall-plan": "The meeting time is 10:00 and the place is the Ferry Building.",
}

CHILD_LOAD = (
    "META-LOAD-TOKEN Read the memory directory before answering the person. "
    "Read the memory directory before answering the person."
)
CHILD_OFF = (
    "META-OFF-TOKEN Update the memory directory after the subtask so the files "
    "survive the cleared session. Update the memory directory after the subtask."
)


def _result(name: str, scores: list[int]) -> RunResult:
    harness = Harness(name, "L" * 80, "O" * 80)
    traces = [
        SubtaskTrace(task.id, score, "answer", [], {})
        for task, score in zip(SUBTASKS, scores, strict=True)
    ]
    return RunResult(harness, traces)


def _tool(name: str, args: dict[str, str], call_id: str) -> dict[str, object]:
    return {
        "role": "assistant",
        "content": None,
        "tool_calls": [
            {
                "id": call_id,
                "type": "function",
                "function": {"name": name, "arguments": json.dumps(args)},
            }
        ],
    }


def _text(content: str) -> dict[str, object]:
    return {"role": "assistant", "content": content}


class PolicyFake:
    """A tool-using stand-in that stores the life facts in files."""

    model = "fake"

    def __init__(self, harness: Harness) -> None:
        self.harness = harness
        self.sister = "Priya Solano"
        self.priya = "sister"
        self.pref = False
        self.plan = False
        self.calls = 0

    def complete(
        self,
        messages: list[dict[str, object]],
        *,
        tool_choice: str = "auto",
        max_tokens: int | None = None,
    ) -> dict[str, object]:
        self.calls += 1
        last = _last_user(messages)
        used = _tools_since_user(messages)
        if last == self.harness.offload:
            if "write_memory" not in used:
                return _tool(
                    "write_memory",
                    {"path": "life.md", "content": self._life()},
                    f"c{self.calls}",
                )
            return _text("Saved.")
        if last == self.harness.load:
            if "list_memory" not in used:
                return _tool("list_memory", {}, f"c{self.calls}")
            blob = json.dumps(messages)
            if "life.md" in blob and "read_memory" not in used:
                return _tool("read_memory", {"path": "life.md"}, f"c{self.calls}")
            return _text("Loaded.")
        task = next(item for item in SUBTASKS if item.prompt == last)
        if task.id == "plan" and "write_memory" not in used:
            return _tool(
                "write_memory",
                {
                    "path": "plan.md",
                    "content": (
                        "Saturday meeting at 10:00 at the Ferry Building, "
                        "then the farmers market."
                    ),
                },
                f"c{self.calls}",
            )
        if task.id == "recall-plan" and "read_memory" not in used:
            return _tool("read_memory", {"path": "plan.md"}, f"c{self.calls}")
        if task.id == "recall-correction" and "read_memory" not in used:
            return _tool("read_memory", {"path": "life.md"}, f"c{self.calls}")
        if task.id == "preference":
            self.pref = True
        if task.id == "plan":
            self.plan = True
        if task.id == "correction":
            self.sister = "Nia Solano"
            self.priya = "cousin"
        return _text(GOLD[task.id])

    def _life(self) -> str:
        lines = [
            "Name: Mira Solano",
            f"Sister: {self.sister}",
            f"Priya Solano: {self.priya}",
        ]
        if self.pref:
            lines.append("Preference: window seat and oat milk")
        if self.plan:
            lines.append("Plan: Saturday 10:00 at the Ferry Building")
        return "\n".join(lines)


class Improving:
    """Seeds score 0. A revision that carries a private token scores 1."""

    model = "fake"

    def complete(
        self,
        messages: list[dict[str, object]],
        *,
        tool_choice: str = "auto",
        max_tokens: int | None = None,
    ) -> dict[str, object]:
        system = str(messages[0].get("content") or "") if messages else ""
        if "meta agent" in system:
            return _text(json.dumps({"load": CHILD_LOAD, "offload": CHILD_OFF}))
        last = _last_user(messages)
        blob = "\n".join(
            str(message.get("content") or "")
            for message in messages
            if isinstance(message.get("content"), str)
        )
        if "META-LOAD-TOKEN" in blob:
            for task in SUBTASKS:
                if task.prompt == last:
                    return _text(GOLD[task.id])
        return _text("ok")


class RefuseRevision:
    model = "fake"

    def complete(
        self,
        messages: list[dict[str, object]],
        *,
        tool_choice: str = "auto",
        max_tokens: int | None = None,
    ) -> dict[str, object]:
        system = str(messages[0].get("content") or "") if messages else ""
        if "meta agent" in system:
            return _text("I cannot revise that.")
        return _text("ok")


def _last_user(messages: list[dict[str, object]]) -> str:
    for message in reversed(messages):
        if message.get("role") == "user":
            content = message.get("content")
            return content if isinstance(content, str) else ""
    return ""


def _tools_since_user(messages: list[dict[str, object]]) -> list[str]:
    names: list[str] = []
    for message in reversed(messages):
        if message.get("role") == "user":
            break
        if message.get("role") != "assistant":
            continue
        calls = message.get("tool_calls") or []
        if not isinstance(calls, list):
            continue
        for call in calls:
            function = call.get("function") or {}
            names.append(str(function.get("name") or ""))
    return names


class HarnessTests(unittest.TestCase):
    def test_gold_answers_score_one_and_traps_score_zero(self) -> None:
        for task in SUBTASKS:
            self.assertEqual(task.score(GOLD[task.id]), 1, task.id)
        by_id = {task.id: task for task in SUBTASKS}
        self.assertEqual(by_id["names"].score("Mira and Priya"), 0)
        self.assertEqual(by_id["preference"].score("oat milk by the window"), 0)
        self.assertEqual(by_id["plan"].score("10am at the market"), 0)
        self.assertEqual(by_id["correction"].score("Your sister is Priya Solano."), 0)
        self.assertEqual(
            by_id["correction"].score(
                "Your sister is not Priya Solano. She is Nia Solano."
            ),
            1,
        )
        self.assertEqual(
            by_id["recall-correction"].score("Your sister is Priya Solano."),
            0,
        )
        self.assertEqual(
            by_id["recall-correction"].score("Nia Solano is your sister."),
            0,
        )
        self.assertFalse(sister_is_priya("Your sister is not Priya Solano."))
        self.assertTrue(sister_is_priya("Your sister is Priya Solano."))

    def test_prompts_are_not_substrings_and_generic_has_no_layout(self) -> None:
        texts = [(f"{item.name} load", item.load) for item in POOL]
        texts += [(f"{item.name} offload", item.offload) for item in POOL]
        for index, (left_name, left) in enumerate(texts):
            self.assertNotIn('"', left, left_name)
            for right_name, right in texts[index + 1 :]:
                self.assertNotIn(left, right, f"{left_name} inside {right_name}")
                self.assertNotIn(right, left, f"{right_name} inside {left_name}")
        generic = GENERIC.load + " " + GENERIC.offload
        for banned in (".md", "README", "skill", "hypothesis", "summary", "retrieval"):
            self.assertNotIn(banned, generic.lower())

    def test_memory_sandbox(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "mem"
            memory = Memory(root)
            self.assertEqual(memory.list_files(), [])
            memory.write("notes/plan.md", "Saturday")
            self.assertEqual(memory.read("notes/plan.md"), "Saturday")
            memory.edit("notes/plan.md", "Saturday", "Sunday")
            self.assertEqual(memory.read("notes/plan.md"), "Sunday")
            for bad in (
                "../secret.md",
                "/tmp/secret.md",
                "notes/../../secret.md",
                "noext",
            ):
                with self.assertRaises(MemoryPathError):
                    memory.write(bad, "nope")
            outside = Path(tmp) / "outside"
            outside.mkdir()
            link = root / "escape.md"
            link.symlink_to(outside / "secret.md")
            with self.assertRaises(MemoryPathError):
                memory.write("escape.md", "nope")
            self.assertFalse((outside / "secret.md").exists())

    def test_swap_replaces_prompts_inside_tool_arguments(self) -> None:
        optimized = Harness(
            "opt",
            "OPTIMIZED LOAD SENTENCE that is not generic.",
            "OPTIMIZED OFFLOAD SENTENCE that is not generic.",
        )
        log = CallLog(
            "plan",
            "offload",
            [
                {"role": "system", "content": "sys"},
                {"role": "user", "content": optimized.load},
                {
                    "role": "tool",
                    "tool_call_id": "1",
                    "content": "listed",
                },
                {"role": "user", "content": optimized.offload},
            ],
            {
                "role": "assistant",
                "content": "done",
                "tool_calls": [
                    {
                        "id": "2",
                        "type": "function",
                        "function": {
                            "name": "write_memory",
                            "arguments": json.dumps(
                                {
                                    "path": "a.md",
                                    "content": optimized.offload + "\nand more",
                                }
                            ),
                        },
                    }
                ],
            },
        )
        record = to_record(log, optimized, GENERIC)
        self.assertEqual(record["messages"][1]["content"], GENERIC.load)
        self.assertEqual(record["messages"][3]["content"], GENERIC.offload)
        self.assertEqual(record["messages"][2]["role"], "tool")
        self.assertEqual(record["assistant"]["role"], "assistant")
        self.assertEqual(record["assistant"]["content"], "done")
        args = json.loads(record["assistant"]["tool_calls"][0]["function"]["arguments"])
        self.assertTrue(args["content"].startswith(GENERIC.offload))
        self.assertNotIn(optimized.offload, args["content"])
        assert_swapped([record], optimized, GENERIC)

    def test_policy_stream_scores_and_swaps(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            memory = Memory(Path(tmp) / "mem")
            logs: list[CallLog] = []
            result = run_stream(
                PolicyFake(SUMMARY),
                SUMMARY,
                memory,
                record=logs,
                budget=Budget(60),
            )
            self.assertEqual(result.scores, [1, 1, 1, 1, 1, 1])
            self.assertIn("Nia Solano", memory.read("life.md"))
            self.assertIn("Ferry Building", memory.read("plan.md"))
            records = [to_record(log, SUMMARY, GENERIC) for log in logs]
            assert_swapped(records, SUMMARY, GENERIC)
            blob = json.dumps(records)
            self.assertNotIn(SUMMARY.load, blob)
            self.assertNotIn(SUMMARY.offload, blob)
            self.assertIn(GENERIC.load, blob)
            saw_tool_context = False
            for record in records:
                self.assertEqual(record["assistant"]["role"], "assistant")
                roles = [message["role"] for message in record["messages"]]
                if "tool" in roles:
                    saw_tool_context = True
            self.assertTrue(saw_tool_context)
            path = Path(tmp) / "distill.jsonl"
            write_jsonl(path, records)
            lines = path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), len(records))
            self.assertEqual(json.loads(lines[0])["assistant"]["role"], "assistant")

    def test_select_and_revision_parsing(self) -> None:
        summary = _result("summary", [1, 1, 1, 1, 1, 0])
        retrieval = _result("retrieval", [1, 1, 1, 1, 1, 0])
        generic = _result("generic", [1, 1, 1, 1, 0, 0])
        self.assertEqual(
            select([summary, retrieval, generic]).harness.name, "retrieval"
        )
        better = _result("hypothesis", [1, 1, 1, 1, 1, 1])
        self.assertEqual(select([summary, better]).harness.name, "hypothesis")
        parent = _result("summary", [1, 1, 1, 1, 0, 0])
        tied = _result("meta-1", [1, 1, 1, 1, 0, 0])
        self.assertFalse(keep_child(parent, tied))
        self.assertTrue(keep_child(parent, _result("meta-1", [1, 1, 1, 1, 1, 0])))
        parsed = parse_revision(
            "```json\n"
            + json.dumps({"load": CHILD_LOAD, "offload": CHILD_OFF})
            + "\n```"
        )
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertEqual(parsed.load, CHILD_LOAD)
        self.assertIsNone(
            parse_revision(
                '{"load": "Mira Solano '
                + ("x" * 80)
                + '", "offload": "'
                + ("y" * 80)
                + '"}'
            )
        )
        self.assertIsNone(parse_revision("not json"))
        self.assertIn("[redacted]", redact("prefix sk-or-v1-testexample suffix"))

    def test_normalize_assistant_joins_text_blocks(self) -> None:
        message = normalize_assistant(
            {
                "content": [{"type": "text", "text": "Hello"}],
                "tool_calls": [{"function": {"name": "list_memory", "arguments": {}}}],
                "reasoning": "look",
            }
        )
        self.assertEqual(message["content"], "Hello")
        self.assertEqual(message["reasoning"], "look")
        self.assertEqual(message["tool_calls"][0]["function"]["arguments"], "{}")

    def test_pipeline_keeps_the_better_child_and_swaps_it_out(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            code = run_pipeline(Improving(), out, budget_s=60, task_max_tokens=640)
            self.assertEqual(code, 0)
            report = (out / "report.md").read_text(encoding="utf-8")
            self.assertIn("Distillation executed: yes", report)
            self.assertIn("A fine-tune did not run.", report)
            self.assertIn("META-LOAD-TOKEN", report)
            dataset = (out / "distill.jsonl").read_text(encoding="utf-8")
            self.assertNotIn("META-LOAD-TOKEN", dataset)
            self.assertNotIn("META-OFF-TOKEN", dataset)
            self.assertIn(GENERIC.load, dataset)
            self.assertIn(GENERIC.offload, dataset)
            for line in dataset.splitlines():
                row = json.loads(line)
                self.assertEqual(row["assistant"]["role"], "assistant")
            self.assertIn("| optimized (meta-1) | 1.000 |", report)
            self.assertIn("| hypothesis | 0.000 |", report)

    def test_unusable_revision_still_distills_the_parent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            code = run_pipeline(RefuseRevision(), out, budget_s=60)
            self.assertEqual(code, 0)
            report = (out / "report.md").read_text(encoding="utf-8")
            self.assertIn("Distillation executed: yes", report)
            self.assertIn("not a usable pair of prompts", report)
            self.assertIn("Optimized harness: `hypothesis`", report)
            dataset = (out / "distill.jsonl").read_text(encoding="utf-8")
            self.assertIn(GENERIC.load, dataset)
            self.assertNotIn(POOL[-1].load, dataset)

    def test_missing_key_is_one_line_and_nonzero(self) -> None:
        env = os.environ.copy()
        env.pop("OPENROUTER_API_KEY", None)
        env.pop("OPEN_ROUTER_API_KEY", None)
        script = Path(__file__).resolve().parent / "run.py"
        completed = subprocess.run(
            [sys.executable, str(script)],
            cwd=script.parent,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr, "OPENROUTER_API_KEY is not set\n")
        self.assertEqual(completed.stdout, "")


if __name__ == "__main__":
    unittest.main()
