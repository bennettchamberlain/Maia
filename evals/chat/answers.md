# A person's question gets a complete human answer

done-when: assistant text on screen and eval wire agree; harness, tool names, action ids, and "what would you like to do" never appear in the reply
provider: openrouter (google/gemini-2.5-flash-lite per /health)

The previous ladder passed, including the GitHub miss that answered from what the tool is able to return. Those prompts are retired below. This run judges the graph: a failed read stays failed, two independent accounts are one step, and a definition does not become a tool call.

## checkpoint required
send: Reply with the single word checkpoint.
setup: signed in as eval, fresh session, default tools
wire: 200, delta, done, no tool
screen: exactly `checkpoint` (trimmed)

## acyclic required
send: In one sentence, what makes a graph acyclic? No tools.
setup: signed in as eval, fresh session
wire: 200, delta, done, no tool
screen: one sentence containing `cycle`; must not contain `what would you like`

## quorinth required
send: What do you remember about the word quorinth? If memory has nothing, say you do not have it. Do not search the web.
setup: signed in as eval, fresh session
wire: 200, delta, done, no web_search, url_read, or computer
screen: contains `quorinth` and `do not have`; must not contain `what would you like` or `action_id`

## capability required
send: The GitHub read did not return. Say what that tool is able to return, and say you do not have the account. Do not invent a login or a repository.
setup: signed in as eval, fresh session
wire: 200, delta, done, tools memory_search then connector, no web_search or computer
screen: contains `able` and `do not have`; must not contain action_id, conn_mod, Call connector, what would you like

## one-read required
send: Read my GitHub account once. If the read fails, do not search the web and do not try again. Say that you do not have the account.
setup: signed in as eval, fresh session
wire: 200, delta, done, tools memory_search then connector, no web_search, url_read, or computer
screen: contains `github` and `do not have`; must not contain action_id, conn_mod, what would you like

## two-apps required
send: What is my GitHub login, and who sent my latest Gmail? They do not depend on each other. For whichever call does not return, say you do not have that one. Do not invent it.
setup: signed in as eval, fresh session
wire: 200, delta, done, tools memory_search then connector then connector, no web_search or computer
screen: contains `github`, `gmail`, and `do not have`; must not contain action_id, conn_mod, Call connector, what would you like

## retired (passed, do not rerun)
ready, arithmetic, water-wet, github-access, austen, primary-colors, github-account. GitHub did not return a login, and the reply still answered from the tool's capability. That pass is why capability, one-read, and two-apps replaced it.

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