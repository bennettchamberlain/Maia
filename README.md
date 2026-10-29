# Requiem

A personal digital memory and a personal AI that lives on your machine.

Requiem remembers people, work, places, and the next honest hour so you do not
have to keep it all in your head. The graph and the policies stay on your
hardware. Cloud services are invited in only when they earn it: cheaper
inference, better search, and connectors you do not want to build yourself.

Memento mori. Twenty-four hours. That is the whole day.

## Why it is split this way

Most “personal AI” products either upload your life to someone else’s cluster
or they starve on a laptop. Requiem does neither as a religion.

**On prem, by default.** Memories, people, places, grants, and the life graph
live in Napalm (Gel on Postgres). Access control is in the schema, not in a
middleware afterthought. If the laptop is closed, the private store is closed.

**Cloud, on purpose.** Parasail runs the large chat and embedding models so a
phone or a thin box is not paying for a 70B locally. You.com grounds a turn
in the live web. withone.ai connects Gmail, Calendar, and GitHub without
Requiem holding those OAuth tokens. MCP lets the same tools show up in Cursor
or any other agent host.

You keep the source of truth. You rent the horsepower.

## Napalm

Napalm is a new database layer for this project. It takes the access-control
instinct of Firebase security rules and writes it into the native schema of a
Postgres graph (Gel).

A request arrives as a person. `current_person` is set on the connection.
Every select, nested select, and graph walk is filtered by policies on the
types themselves: who may see a memory, at what disclosure, along which
relationship tier. You do not fetch a subgraph and then filter it in
application code. The database refuses the rows.

That is what makes deep traversal cheap to think about. “Friends of this
person, their places, the memories at those places this week” is one query.
Nested shapes come back as nested JSON. Chat can ask for that graph in
natural language; the host tools emit named EdgeQL, not ad-hoc SQL pasted
into a prompt.

Vectors sit next to the rows (`pgvector`). Local embeddings and Parasail
cloud embeddings are both first-class columns. Files stay with the node they
belong to.

## GenUI

Agent tools do not only return prose. They return **GenUI**: a small typed
tree (cards, lists, search results, graph edges, checks) that the Flutter
client draws. A web search is a set of cards. A weave is edges you can
confirm. The model can talk, and the screen can show the structure it used.

## Cloud services Requiem actually uses

### You.com

Grounding, not a second brain.

- **Search HTTP:** `https://api.you.com/v1/search` from the `web_search` chat
  tool (`YDC_API_KEY` or `YOU_WEB_SEARCH_TOKEN`).
- **MCP:** `https://api.you.com/mcp` for agent hosts, plus
  `https://you.com/docs/_mcp/server` for You.com’s own docs.
- **Plugins / skills:** the repo ships You.com-oriented skills (search,
  research, finance, discover) so an editor agent can use the same endpoints
  Requiem’s chat tool uses.

A You.com key can live in `.env` or be pasted from the app. It never becomes
the memory store.

### withone.ai

Connectors without becoming a Google/GitHub OAuth shop.

- **Connect:** the `connect/` sidecar speaks `@withone/connect`. The Flutter
  app stays on the Requiem API host (`/one/authorize`, `/one/connect`,
  `/one/sync`). Tokens stay at One. Requiem stores a grant pointer and
  platforms (Gmail, Google Calendar, GitHub).
- **MCP:** `https://mcp.withone.ai/mcp` so the same connections are usable
  from an MCP client.
- **ETL:** workers pull through One (`ONE_SECRET` / `ONE_CONNECTION_KEYS`)
  and upsert memories. No One keys means no live pull; the UI must not fake
  a connection.

### Parasail

Serverless inference and embeddings when local Ollama is the wrong cost
curve.

- Chat: `PARASAIL_BASE_URL` (default `https://api.parasail.io/v1`),
  `PARASAIL_MODEL` (default `parasail-glm-53-flash`).
- Embeddings: `PARASAIL_EMBED_MODEL` (BGE-M3, 1024-d) into the cloud vector
  column.
- Voice brain: PersonaVoice can think on Parasail while speech stays on the
  device or a local sidecar.

`SCORIA_CHAT_PROVIDER=auto` prefers Parasail, then Ollama. The graph does
not move just because the model did.

### MCP and plugins

`.cursor/mcp.json` wires You.com and One into Cursor. The tree also has an
MCP server/client path so Requiem can host tools and consume other people’s
servers. Plugins and skills in `.agents/skills` are how editor agents share
the same You.com / One / payments contracts as the running app.

## Layout

```
schema/     Napalm / Gel schema, policies, named EdgeQL
server/     Dart API, jobs, PersonaVoice sidecar
app/        Flutter client (iOS, web, desktop)
packages/   Shared models and API client
connect/    withone.ai Connect sidecar
etl/        One → memory workers
swarm/      Weaver (Parasail + You.com)
```

Older application code also lives under `frontend/` and `backend/`. The
product you run for Requiem is the schema / server / Flutter stack above.

## Run

```sh
cp .env.example .env
# fill YDC_API_KEY, PARASAIL_API_KEY, ONE_* if you want those planes

set -a && source .env && set +a
export HACKATHON_ROOT="$PWD"
export SCORIA_PYTHON="$PWD/.venv/bin/python"
export SCORIA_QUERIES_DIR="$PWD/schema/queries"
export SCORIA_PORT=8090
cd server/scoria_api && dart run bin/main.dart
```

Flutter talks to `http://localhost:8090` on the same machine, or the Mac’s
Tailscale/LAN address from a phone. Handle `admin`, password `scoria-admin`
on a fresh local box.

```sh
cd app
flutter run -t lib/main_development.dart --flavor development
```

PersonaVoice is optional. If the sidecar is down, chat still types, and the
phone can still listen locally.

## What stays yours

Keys in `.env` are not committed. Session tokens are yours. One’s OAuth
tokens are One’s. Napalm policies decide who can read a nested walk, including
you asking your own agent. That is the product: a memory that can go deep
without going public.

## License

MIT. Copyright Bennett Chamberlain, 2026.
