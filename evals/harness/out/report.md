# Maia memory harness distillation

Distillation executed: no

A fine-tune did not run. The runner writes a swapped-prompt dataset and this report. It does not train a model.

Recorded 2026-11-17 21:15 PST.

## Why the model run is blocked

`OPENROUTER_API_KEY` is unset in this environment, and `OPEN_ROUTER_API_KEY` is unset as well. `python3 evals/harness/run.py` exits before any model call in that case, with the one-line message `OPENROUTER_API_KEY is not set`. No key was read from a file.

Instabox has no saved login on this machine. `instabox` is not on PATH, `~/.config/instabox/credentials.json` is absent, and `INSTABOX_API_KEY` is unset. The CLI was not installed, and `instabox login` was not started, because an install would have no existing login to reuse.

Box `box-d63cd7` (id `m_agq6zo5qgpibuedkxbfdth4owe`) was not started. No second box was created. This run could not call `instabox get` without a login. It did not wake the box. The state given for the task was stopped.

## Scores

Not collected. Generic, Summary, Retrieval, Skill, Hypothesis, the meta revision, and the optimized demonstration pass did not call a model.

## Optimized LOAD and OFFLOAD

None. The search did not run, so there is no winning pair.

## Dataset

`evals/harness/out/distill.jsonl` was not produced.

The swap step did run offline. `python3 evals/harness/test_harness.py` (10 tests, all passing on this machine) drives the same pipeline with a scripted agent. The demonstration log is rewritten so LOAD and OFFLOAD in the context are the generic prompts, assistant text and tool calls stay the supervised targets, and tool results stay in context. That check passed. It is not a score for `anthropic/claude-sonnet-4.5`.

## Command

From the repo root, with `OPENROUTER_API_KEY` set:

```bash
python3 evals/harness/run.py
```

Default model: `anthropic/claude-sonnet-4.5`. A finished run overwrites this report and writes `evals/harness/out/distill.jsonl`. One pass each of the generic harness and the four seeds, one meta revision of the winner, then one demonstration pass whose prompts are swapped back to the generic pair.
