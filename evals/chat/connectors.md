# Connected apps are read, then answered

done-when: GitHub names a login or a repo, or says which of those it cannot see. Gmail names the sender and the point of the latest message, or says the mailbox cannot be seen. Neither reply lists actions or says it does not understand.
provider: the server the desktop app is signed into

## github-login required
send: What is my GitHub login, and name one repository on that account? If you cannot see either, say which one you do not have.
wire: 200, delta, done. A connected account includes a connector tool event.
screen: one answer. No action_id, conn_mod, Call connector, copied, or what would you like.

## gmail-latest required
send: What is the latest email in my Gmail about, and who sent it? Answer with the sender and the point of the message. If you cannot see the mailbox, say so.
wire: 200, delta, done. A connected mailbox includes a connector tool event.
screen: sender and what they wanted, or an honest miss. No action ids, no "copied", no "I don't understand".

## gmail-reply required
send: Should I reply to the latest Gmail message? Yes or no, then why, using only what that message says. If you cannot see it, say so.
wire: 200, delta, done.
screen: yes or no with a reason taken from the message, or an honest miss. No action ids.

### connectors round 1
prompt: GitHub login and one repository, then the latest Gmail and whether to reply
wire: the eval person has no One grant. On the signed-in account, GitHub called connector twice and One refused it (`one_error`) after filling the login with the word GitHub. Gmail's first call returned the action list; the reply asked which action to run (Send Email, List and View Email Threads, List and View Email Drafts). The reply call was refused the same way.
screen: "I do not have your GitHub login or any repositories." / the action menu / "I cannot see the latest Gmail message."
result: fail
change: a read now runs in the same step, the mail body is what the model reads, a queued sync still reads the account, and a connection named GitHub or Gmail is not treated as the login. The process that answered is on the other machine and was not restarted.

### connectors round 2
prompt: GitHub login and one repository, signed in as the desktop account. Then the word quorinth.
wire: GitHub was `user tool tool delta delta done`, tools `memory_search` then `connector`. Memory came back as a card of neighbors. Connector came back as an action catalog, so the One sidecar on the answering machine is still the old one. The reply was a short miss, with no tool lecture. Quorinth was `user tool delta delta done`, tool `memory_search`, class neighbor, and the reply said it does not have the word.
screen: the Mac client now hides a memory card that does not contain the asked word, and hides every memory card on an account read. Select-all covers the thread.
result: fail. The call is made. The sidecar that answered still returned the action list instead of the account.

### connectors round 3
prompt: latest Gmail, calendar today, Google Drive, Google Docs, LinkedIn, Figma, Supabase, X. Signed in as the desktop account.
platforms on that account: figma, x, google-calendar, github, gmail, supabase, linked-in. Drive and Docs are not connected.
wire: every question called memory_search then connector. Gmail and LinkedIn came back as an action catalog. Calendar, Drive, Figma, Supabase, and X came back as "Checked memory first", so the live read never ran. Drive and Docs have no account to call.
result: fail
change: the desk now knows gmail, google-calendar, google-drive, google-docs, github, linked-in, figma, supabase, and x. A question about the day, the inbox, or a file reads that slug. A reply, a send, a new event, or a new file is a second call only when they asked for the change. "Should I reply" stays a judgment. The answering process has not been restarted with this tree.
