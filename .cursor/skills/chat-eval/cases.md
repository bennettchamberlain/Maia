# Case file

One file per feature: `evals/chat/<slug>.md`. The loop in [SKILL.md](SKILL.md) runs the required cases in order and stops at the first red one.

```markdown
# <feature, one sentence>

done-when: <screen plus wire>
provider: <from /health, filled at runtime>

## <id> required | advisory
send: <the user message, or "empty composer">
setup: <session, tool prefs, signed in or not>
wire: <status and the events that must appear or must not>
screen: <the part the user must see, or must not>
```

A wire line names events, not a transcript. `tool web_search` means an SSE `tool` event whose `name` is `web_search` and whose `result` is not an error string. `no 400` means the message request is not HTTP 400 and the transcript does not contain `INVALID_ARGUMENT`.

## Worked case: tool replay

This is the failure where a search turn paints `agent 400` and `Function call is missing a thought_signature` for `default_api:web_search`.

```markdown
# Search turns survive the follow-up request

done-when: a web search renders as a search part, and the next message still completes
provider: gemini-compatible

## search-renders required
send: Search the web for the weather in Lisbon tomorrow
setup: signed in, web_search enabled
wire: 200, tool web_search, finish, no 400
screen: a search part, no raw agent 400

## replay-keeps-signature required
send: And the day after?
setup: same session, immediately after search-renders
wire: 200, finish, no thought_signature error
screen: assistant text, no raw agent 400

## search-off advisory
send: Search the web for the weather in Lisbon tomorrow
setup: web_search disabled in chat prefs
wire: 200, no tool web_search, finish
screen: assistant text, no search part
```

`replay-keeps-signature` is the case that catches a follow-up which drops `thought_signature` when it rebuilds the assistant `tool_calls` message. A green `search-renders` does not cover it.
