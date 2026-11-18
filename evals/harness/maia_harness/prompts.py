"""Generic harness and the four seed strategies.

LOAD runs before a subtask. OFFLOAD runs after it. The session is then
cleared. Generic prompts are task-independent and name no file layout.
Each seed is a concrete way to remember one person's life.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Harness:
    name: str
    load: str
    offload: str


SYSTEM = (
    "You are Maia, remembering one person's life across cleared sessions. "
    "You can list, read, write, and edit markdown files in a memory directory. "
    "Those files are the only memory that survives after a session ends. "
    "Use the tools when you need them. When you are ready to answer the person, "
    "stop calling tools and reply in plain text with the facts they asked for. "
    "Do not invent a name, preference, plan, or relationship that is not in this "
    "conversation or in a file you have read."
)

GENERIC = Harness(
    "generic",
    (
        "Before you work on the next subtask, you may read your memory directory "
        "with the file tools. Anything from an earlier session is only in those "
        "files. You may also wait and read after the subtask is visible."
    ),
    (
        "The subtask is finished. You may update your memory directory with the "
        "file tools so a later session can continue. The conversation context "
        "will then be cleared, and only the files will remain."
    ),
)

SUMMARY = Harness(
    "summary",
    (
        "Use one running summary as memory. Before you answer, list the "
        "directory and read the summary note in full if a note is there. That "
        "note is the current record of this person's life. You may read it now "
        "or as soon as the subtask is visible."
    ),
    (
        "Update one running summary of this person's life. Rewrite a single "
        "note with the current names, relationships, preferences, and plans. "
        "When a fact is corrected, keep the new fact and drop the old one. Do "
        "not leave two notes that disagree."
    ),
)

RETRIEVAL = Harness(
    "retrieval",
    (
        "Retrieve notes by what the subtask asks. List the memory directory. "
        "Before you answer, open each note about the people, preferences, or "
        "plans the subtask mentions, and leave unrelated notes closed. You may "
        "open them as soon as the subtask is visible."
    ),
    (
        "Store one note per fact. Write or replace a separate note for each "
        "name, relationship, preference, plan, and correction this subtask "
        "established. Name each note for its fact. When a fact is corrected, "
        "replace the old note so a later lookup finds only the current fact."
    ),
)

SKILL = Harness(
    "skill",
    (
        "Use a skill note plus fact notes. List the memory directory. Before "
        "you answer, read the skill note that records how to store and recall "
        "this person's life, then open the fact notes that procedure points "
        "to. You may do this as soon as the subtask is visible."
    ),
    (
        "Maintain a skill note and the fact notes it governs. Update the skill "
        "note with the procedure for names, preferences, plans, and "
        "corrections, including how a correction retires an old fact. Then "
        "follow that procedure and update the fact notes with what this "
        "subtask taught."
    ),
)

HYPOTHESIS = Harness(
    "hypothesis",
    (
        "Use a hypothesis note. List the memory directory and read it before "
        "you answer. Trust a fact only when it is marked supported. Ignore a "
        "fact marked dropped. You may read the note as soon as the subtask is "
        "visible."
    ),
    (
        "Update the hypothesis note. Record each new fact as supported. When "
        "the person corrects a fact, mark the old fact dropped and mark the "
        "replacement supported. Keep each preference and each plan as its own "
        "supported entry."
    ),
)

# Generic first, then the four seeds from the paper.
POOL: tuple[Harness, ...] = (GENERIC, SUMMARY, RETRIEVAL, SKILL, HYPOTHESIS)

# Higher wins only when mean score and the last two subtasks are tied.
TIE_BIAS: dict[str, int] = {
    "hypothesis": 4,
    "skill": 3,
    "retrieval": 2,
    "summary": 1,
    "generic": 0,
}

# A revision that bakes the train person's facts into the prompt is rejected.
FACT_WORDS: tuple[str, ...] = (
    "mira",
    "priya",
    "nia",
    "solano",
    "ferry",
    "oat",
)
