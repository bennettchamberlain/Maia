---
name: chat-eval
description: >-
  Recursively test a Maie chat feature by connecting another client to the
  server the desktop app already uses, until the required cases pass. Use
  when the user says recursively test chat, eval a chat feature, spin up
  evals, test until it works, set up the test client, or turn a chat PRD
  into cases. The server stays up and keeps its other clients.
---

# Chat eval

One feature, one box, one loop. A case passes only when the Flutter screen and the API wire agree. A PRD is a queue of features. Finish one before opening the next.

The server is the one already running. The desktop app is one client of it. The eval is another client, signed in as its own person, so its sessions stay off the desktop person's list. Do not start a second API.

## Connect

From the repo root, once, before a loop:

```sh
cd evals/chat && dart run bin/chat_eval.dart setup
```

`setup` reads the desktop app's saved server URL, checks `GET /health`, and signs in as `eval`. The first time, it creates that person through the desktop account (`maie`). It then opens two connections as `eval` and one as `maie`, and checks that the second eval connection sees the probe session and `maie` does not. The URL and the eval password go in `evals/chat/client.local`, which is gitignored. Do not print that file.

A later case sends as that same client:

```sh
cd evals/chat && dart run bin/chat_eval.dart send "the prompt for this case"
```

`send` opens a new session so cases do not share a transcript. Exit 0 is a finished turn. Exit 1 is an `error` event. The wire line names the events.

Pass `--url` when the desktop app is pointed somewhere else. Pass `--handle eval-<slug>` only for a second eval that must stay out of the first eval's sessions. The server already accepts both at once.

An instabox (`npx instabox@latest sh`, then `instabox ssh`) may run this same client when that box can reach the server URL. It still does not start maie-api. A cloud box cannot see a tailnet address unless Tailscale is up there. Run the driver on the machine that already reaches the server.

A screen check uses the Flutter app pointed at the same URL, signed in as `eval`, not as the desktop person. Restart the process that owns a fix. A server change is a new `dart` process on the server machine. A widget change is a Flutter restart. Hot reload does not count as a rerun.

## Loop

Copy this and keep it current:

```
Feature:
Done when:
Round: 1 of 8
- [ ] Happy path written and run
- [ ] Edges written from the contract or the failure
- [ ] Red case fixed with the smallest change
- [ ] Red case rerun
- [ ] Every required case green
```

1. Name the feature in one sentence. Take done-when from the PRD. If there is no PRD, write one only for this feature: who does what, what the screen shows, what the wire returns.
2. Write the happy-path case in [cases.md](cases.md). Run it on the live client.
3. Write edges from what this feature can actually hit. One case, one behavior. A passing happy path still gets its edges. A failing one gets the edges the failure revealed, plus the ones the contract already implies.
4. Fix the smallest code that turns the current red case green. Stay inside that feature.
5. Rerun the red case, then every required case for the feature.
6. Stop when every required case is green, or at round 8 with cases still red. Write what is still red. Do not open the next feature.
7. Append the evidence to `evals/chat/<slug>.md`. Do not commit unless the user asks. Do not commit `client.local`.

A case that passes before the production change is not evidence. Tighten it or pick the behavior it failed to pin.

## Oracles

Every case has two checks. Both must pass.

- **Wire.** Status and SSE from `POST /chat/sessions/<id>/messages`. Events the client understands are `user`, `delta`, `tool`, `done`, and `error`. A `400` body or an `error` event is a fail, even if later text looks fine.
- **Screen.** The GenUI the user would see: assistant text, a search part for `web_search`, or the error alert. A screenshot that disagrees with the wire is a fail.

Standing tool-round oracle. Some providers (Gemini, and any OpenAI-compatible route that speaks its function-call parts) attach a `thought_signature` to a function call. The next request must send that signature back on the same part. `Function call is missing a thought_signature` (the `default_api:web_search` 400) is a fail of the tool round. The replay lives in `runChatTurn`: the assistant message it appends keeps `id`, `type`, and `function` only. A signature on the stream that is dropped before the follow-up request is the defect. Do not "fix" it by hiding the error string in the widget.

## Edges worth a case

Include an edge only when this feature can hit it. Mark it `required` or `advisory`. Advisory is recorded and does not block unless the PRD says it does.

- Empty composer sends nothing.
- First turn with tools off: text lands in the open session, no tool event.
- Tool turn: `web_search` becomes a search part, not a raw 400.
- The next user message after a tool call (the replay).
- That tool disabled in chat prefs.
- A second session does not show the first session's messages.
- Signed-out send is a 401, and the spinner stops.
- The stream ends with `finish`.
- The provider the box is actually on (`MAIE_CHAT_PROVIDER` and `/health`). Do not require Parasail on an Ollama box.

## A PRD

Split the PRD into features in order. Each feature gets its own file, `evals/chat/<slug>.md`, and its own loop. Spin another eval by starting that file's loop, not by widening the current one.

Evals share the server. They do not share a person: the default handle is `eval`, and a parallel feature uses `--handle eval-<slug>`. Two features that both edit `server/maie/lib/src/chat/turn.dart` are never parallel.

## Evidence

Append this for every round:

```
### <slug> round <n>
prompt: <what was sent>
wire: <status, event names, and the failing body if any>
screen: <what Chromium showed>
result: pass | fail | blocked
change: <files touched, or none>
```

Keep the failing body when it is the oracle (the thought_signature 400 is the point). Cut headers and tokens.

## Do not

- Call `dart test` or `flutter test` the frontend result. Those can support a fix. The pass is the live client.
- Hide an upstream 400 in the chat widget and call the feature done.
- Start feature N+1 inside feature N's fix.
- Start a second API, print `client.local`, or write the eval password into a case file.
