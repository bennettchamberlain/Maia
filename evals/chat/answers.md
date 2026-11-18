# A person's question gets a complete human answer

done-when: assistant text on screen and eval wire agree; harness, tool names, action ids, and "what would you like to do" never appear in the reply
provider: openrouter (google/gemini-2.5-flash-lite per /health)

## ready required
send: Reply with the single word ready.
setup: signed in as eval, fresh session, default tools
wire: 200, delta, done, no tool
screen: exactly `ready` (trimmed)

## arithmetic required
send: What is 2+2? Reply with the number only.
setup: signed in as eval, fresh session
wire: 200, delta, done, no tool
screen: exactly `4`

## water-wet required
send: Is water wet? Yes or no, then one reason.
setup: signed in as eval, fresh session
wire: 200, delta, done, no tool
screen: one short yes/no answer; must not contain `what would you like`

## github-access required
send: Do you have access to GitHub?
setup: signed in as eval, fresh session, connector enabled when connected
wire: 200, delta, done
screen: one sentence; must not contain action_id, conn_mod, Call connector, what would you like

## austen required
send: Who wrote Pride and Prejudice? Name only.
setup: signed in as eval, fresh session
wire: 200, delta, done
screen: contains Austen; must not dump a search heading or five snippets

## primary-colors required
send: Name the three primary colors, one per line, and nothing else.
setup: signed in as eval, fresh session
wire: 200, delta, done, no tool
screen: three color lines, either red/green/blue or red/yellow/blue, nothing else

## github-account required
send: What is in my GitHub account right now? If you cannot see a repo or a login, say you do not have it. Do not list actions.
setup: signed in as eval, fresh session
wire: 200, delta, done
screen: real repo/login fact or honest miss; must not contain action_id or conn_mod

### answers round 1
prompt: Reply with the single word ready.
wire: user delta delta done
screen: ready
result: pass
change: none (eval client only; server fix local)

### answers round 1
prompt: What is 2+2? Reply with the number only.
wire: user delta done
screen: 4
result: pass
change: none

### answers round 1
prompt: Is water wet? Yes or no, then one reason.
wire: user delta delta delta done
screen: No. Wetness is a measure of a liquid's ability to adhere to the surface of a solid. Water itself is not wet, but it can make other objects wet.
result: pass
change: none

### answers round 1
prompt: Do you have access to GitHub?
wire: user delta delta delta done (no tool on wire; eval person has no connected github on this server)
screen: I do not have direct access to GitHub. I can search the public web, which might provide information about GitHub, but I cannot interact with it directly.
result: pass
change: server — `publicChatText`, connector `type: model`, delta filter in `turn.dart` (not deployed on 100.86.127.113 yet; this turn did not hit connector)

### answers round 1
prompt: Who wrote Pride and Prejudice? Name only.
wire: user delta delta done
screen: Jane Austen.
result: pass
change: none

### answers round 1
prompt: Name the three primary colors, one per line, and nothing else.
wire: user delta delta done
screen: Red\nYellow\nBlue
result: pass
change: none. Pigment primaries are a right answer. The check had required green.

### answers round 1
prompt: What is in my GitHub account right now? If you cannot see a repo or a login, say you do not have it. Do not list actions.
wire: user delta delta delta done
screen: I do not have access to your GitHub account. Therefore, I cannot see any repositories or login information.
result: pass
change: none