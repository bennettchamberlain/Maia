# Search turns survive the follow-up request

done-when: a web search renders as a search part, and the next message still completes
provider: not observed — this VM has no Gemini key, so `/health` was not a Gemini process

## search-renders required
send: Search the web for the weather in Lisbon tomorrow
setup: signed in, web_search enabled
wire: 200, tool web_search, finish, no 400
screen: a search part, no raw agent 400

## replay-keeps-signature required
send: And the day after?
setup: same session, immediately after search-renders (`chat_eval send --session <id>`)
wire: 200, finish, no thought_signature error
screen: assistant text, no raw agent 400

## Evidence

Live cases were not run. `GOOGLE_GEMINI_API_KEY` and `GEMINI_API_KEY` are unset, Cursor app secrets for this workspace are empty, and no local secret store on the VM held a key. A unit test is not the pass. search-renders and replay-keeps-signature are blocked, not green.

The same OpenAI-compat endpoint (`https://generativelanguage.googleapis.com/v1beta/openai/chat/completions`) was recorded on 2026-10-14 for `gemini-3.1-flash-lite` (pydantic-ai cassette `test_compatible_api_gemini_3_tool_call_thought_signature[True]`). That is not a capture of `gemini-3-flash-preview` from this run. In that recording the tool-call chunk has no `index` on the tool call, and the signature is:

`choices[0].delta.tool_calls[0].extra_content.google.thought_signature`

The follow-up that returned 200 echoed that object on the assistant `tool_calls` entry (`content: null`) and sent tool results as `{role, tool_call_id, content}`. A text finish on the same stream put a second signature on `choices[0].delta.extra_content.google.thought_signature`, beside no `tool_calls`.

### tool-replay round 1
prompt: Search the web for the weather in Lisbon tomorrow
wire: blocked, no request. Key probe exit 2 (`GOOGLE_GEMINI_API_KEY` / `GEMINI_API_KEY` absent).
screen: not opened. No Gemini server was started.
result: blocked
change: `server/maia/lib/src/agent.dart` keeps a signature that arrives on the tool call, inside `function`, or on `delta` beside `tool_calls` (including a later chunk) and copies a carried one onto the first tool call that lacks it. Parallel tool calls that omit `index` stay separate. A `thought_signature` 400 is not retried with tools stripped. `server/maia/lib/src/chat/turn.dart` stores `call_id` plus the provider fields and replays them on the next turn; tool results are `{role, tool_call_id, content}`. `server/maia/lib/src/app.dart` uses that replay. The sibling-delta test failed on the previous parser (`toWire()['extra_content']` was null) before this change.

### tool-replay round 1 replay
prompt: And the day after?
wire: not sent. Same block as search-renders.
screen: not opened
result: blocked
change: same as round 1. Not a pass.
