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
