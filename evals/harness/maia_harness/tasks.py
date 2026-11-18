"""Six life-memory subtasks and deterministic 0/1 checks.

Context is empty at the start of every subtask. The first four teach a
fact that is still on screen. The fifth needs the corrected sister fact.
The sixth needs the Saturday plan the agent should have written to a file.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass


def norm(text: str) -> str:
    return " ".join(text.lower().split())


def has_meeting_time(text: str) -> bool:
    folded = norm(text)
    return any(token in folded for token in ("10:00", "10 am", "10am", "10 a.m."))


_SISTER_IS_PRIYA = re.compile(
    r"sister(?:'s name)? is priya\b|priya solano is (?:my |your )?sister\b"
)


def sister_is_priya(text: str) -> bool:
    return _SISTER_IS_PRIYA.search(norm(text)) is not None


def _names(answer: str) -> int:
    folded = norm(answer)
    return int("mira solano" in folded and "priya solano" in folded)


def _preference(answer: str) -> int:
    folded = norm(answer)
    return int("window seat" in folded and "oat" in folded)


def _plan(answer: str) -> int:
    folded = norm(answer)
    return int(has_meeting_time(answer) and "ferry building" in folded)


def _correction(answer: str) -> int:
    folded = norm(answer)
    return int("nia solano" in folded and not sister_is_priya(answer))


def _recall_correction(answer: str) -> int:
    folded = norm(answer)
    return int(
        "nia solano" in folded
        and "priya" in folded
        and "cousin" in folded
        and not sister_is_priya(answer)
    )


@dataclass(frozen=True)
class Subtask:
    id: str
    prompt: str
    check: Callable[[str], int]

    def score(self, answer: str) -> int:
        return 1 if self.check(answer or "") == 1 else 0


SUBTASKS: tuple[Subtask, ...] = (
    Subtask(
        "names",
        (
            "Remember this about me. My name is Mira Solano. My sister is "
            "Priya Solano. Reply with both full names so I know you heard them."
        ),
        _names,
    ),
    Subtask(
        "preference",
        (
            "Remember a preference. I always choose the window seat, and I "
            "take my coffee with oat milk. Reply with the seat and the milk."
        ),
        _preference,
    ),
    Subtask(
        "plan",
        (
            "Remember a plan. On Saturday I will meet my sister at 10:00 at "
            "the Ferry Building, then walk the farmers market. Save this plan "
            "in a memory file, and reply with the meeting time and the "
            "meeting place."
        ),
        _plan,
    ),
    Subtask(
        "correction",
        (
            "Correction: my sister is not Priya Solano. My sister is Nia "
            "Solano. Priya Solano is my cousin. Reply with my sister's "
            "corrected full name."
        ),
        _correction,
    ),
    Subtask(
        "recall-correction",
        (
            "Using only your memory files, what is my sister's name after the "
            "correction, and what is Priya Solano to me?"
        ),
        _recall_correction,
    ),
    Subtask(
        "recall-plan",
        (
            "Open the memory file that holds my Saturday plan and answer from "
            "that file. What is the meeting time and the meeting place?"
        ),
        _plan,
    ),
)
