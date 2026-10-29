import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";

loadEnv({ path: join(dirname(fileURLToPath(import.meta.url)), "..", ".env") });

const PORT = Number(process.env.CONNECT_PORT || 8788);
const SCORIA = (process.env.SCORIA_API_URL || "http://127.0.0.1:8080").replace(/\/$/, "");
const INTERNAL = process.env.SCORIA_INTERNAL_SECRET || "";
const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "public", "index.html"), "utf8");

const userStore = {
  async saveUser(appUserId, oneUser) {
    const oneUserId = oneUser.id || oneUser.oneUserId || String(oneUser);
    const spaceId = oneUser.spaceId;
    const post = (platforms) =>
      fetch(`${SCORIA}/internal/one/grant`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-scoria-internal": INTERNAL },
        body: JSON.stringify({
          person_id: appUserId,
          one_user_id: oneUserId,
          space_id: spaceId,
          platforms,
        }),
      });
    await post(Array.isArray(oneUser.platforms) ? oneUser.platforms : []);
    if (!connect?.listConnections) return;
    try {
      const rows = await connect.listConnections(appUserId);
      const platforms = [
        ...new Set(rows.map((row) => row.platform).filter(Boolean)),
      ];
      await post(platforms);
    } catch (err) {
      console.warn("One listConnections after grant:", err.message);
    }
  },
  async loadUser(appUserId) {
    const r = await fetch(`${SCORIA}/internal/one/grant`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-scoria-internal": INTERNAL },
      body: JSON.stringify({ person_id: appUserId, lookup: true }),
    });
    if (!r.ok) return null;
    const row = await r.json();
    if (!row?.one_user_id) return null;
    return { id: row.one_user_id, spaceId: row.space_id };
  },
  async clearUser(appUserId) {
    await fetch(`${SCORIA}/internal/one/grant`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-scoria-internal": INTERNAL },
      body: JSON.stringify({ person_id: appUserId, revoked: true }),
    });
  },
};

let connect;
let handlers;
try {
  const mod = await import("@withone/connect/server");
  const handlersMod = await import("@withone/connect/node");
  if (process.env.ONE_CLIENT_ID && process.env.ONE_CONNECT_KEY) {
    connect = mod.createOneConnect({
      clientId: process.env.ONE_CLIENT_ID,
      clientSecret: process.env.ONE_CLIENT_SECRET,
      redirectUri: process.env.ONE_REDIRECT_URI,
      permissionSet: process.env.ONE_PERMISSION_SET,
      connectKey: process.env.ONE_CONNECT_KEY,
      userStore,
    });
    handlers = handlersMod.createOneConnectHandlers(connect, {
      identifyUser: async (req) => {
        const url = new URL(req.url, "http://local");
        return url.searchParams.get("person") || req.headers["x-scoria-person"] || null;
      },
    });
  }
} catch (err) {
  console.warn("One Connect SDK not configured:", err.message);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  if (url.pathname === "/" || url.pathname === "/index.html") {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(html);
    return;
  }
  if (url.pathname === "/api/one/connections" && req.method === "GET") {
    if (!connect) {
      res.writeHead(503, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "one_unconfigured", accounts: [] }));
      return;
    }
    const person = url.searchParams.get("person");
    if (!person) {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "person required" }));
      return;
    }
    try {
      const rows = await connect.listConnections(person);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({
        accounts: rows.map((row) => ({
          platform: row.platform,
          name: row.name || row.title || row.platform,
          access: row.access?.policy || "",
        })),
      }));
    } catch (err) {
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: err.message || "list failed" }));
    }
    return;
  }
  if (url.pathname === "/api/one/pull" && req.method === "POST") {
    if (!connect) {
      res.writeHead(503, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "one_unconfigured" }));
      return;
    }
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString() || "{}");
    const person = body.person;
    const platform = body.platform;
    if (!person || !platform) {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "person and platform required" }));
      return;
    }
    try {
      const rows = await connect.listConnections(person);
      const conn = rows.find((row) => row.platform === platform);
      if (!conn) {
        res.writeHead(404, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: `no grant for ${platform}` }));
        return;
      }
      const intent = body.intent || "list recent records";
      const actions = await connect.searchActions(person, platform, intent);
      const action = actions[0];
      if (!action) {
        res.writeHead(404, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: `no action for ${platform}` }));
        return;
      }
      const reply = await connect.runAction(person, {
        connectionKey: conn.key,
        actionId: action._id,
        query: { maxResults: "25" },
      });
      res.writeHead(reply.ok ? 200 : reply.status || 502, {
        "content-type": "application/json",
      });
      res.end(JSON.stringify(reply.data ?? { blocked: reply.blockedByGrant }));
    } catch (err) {
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: err.message || "pull failed" }));
    }
    return;
  }
  if (url.pathname.startsWith("/api/one/")) {
    if (handlers) {
      const action = url.pathname.split("/").pop();
      req.url = url.pathname + url.search;
      if (typeof handlers === "function") {
        return handlers(req, res);
      }
      const fn = handlers[action] || handlers.GET || handlers.handle;
      if (fn) return fn(req, res);
    }
    res.writeHead(503, { "content-type": "text/html; charset=utf-8" });
    res.end(`<!doctype html><meta charset="utf-8"><title>One Connect</title>
<body style="font:16px/1.4 system-ui;max-width:36rem;margin:3rem auto">
<h1>One is not configured</h1>
<p>This Requiem has no <code>ONE_CLIENT_ID</code> / <code>ONE_CONNECT_KEY</code> yet, so there is nothing to authorize.</p>
<p>Create an app at <a href="https://app.withone.ai/developers/connect">app.withone.ai/developers/connect</a>, put the keys in <code>.env</code>, restart Connect, then come back from the Tools tab.</p>
</body>`);
    return;
  }
  if (url.pathname === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, connect: Boolean(connect) }));
    return;
  }
  res.writeHead(404);
  res.end("not found");
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`one-connect on :${PORT} (sdk=${Boolean(connect)})`);
});
