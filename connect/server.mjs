import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { parseUserReference } from "@withone/connect/server";
import { rankActions } from "./actions.mjs";
import { accountLogin, fillPathParams } from "./path_params.mjs";

loadEnv({ path: join(dirname(fileURLToPath(import.meta.url)), "..", ".env") });

const PORT = Number(process.env.CONNECT_PORT || 8788);
const MAIA = (process.env.MAIA_API_URL || "http://127.0.0.1:8080").replace(/\/$/, "");
const INTERNAL = process.env.MAIA_INTERNAL_SECRET || "";
const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "public", "index.html"), "utf8");

const PERSON = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// OAuth state -> Maia person. The callback URL has no ?person=, and
// folded Set-Cookie headers can drop maia_person. The PKCE cookie is
// enough for One; this map is enough for us.
const pendingPeople = new Map();

function cookiePath() {
  try {
    const path = new URL(process.env.ONE_REDIRECT_URI).pathname.replace(/\/[^/]*$/, "");
    return path || "/";
  } catch {
    return "/one";
  }
}

function readCookie(req, name) {
  const header = req.headers.cookie || "";
  for (const part of header.split(";")) {
    const [rawName, ...rest] = part.trim().split("=");
    if (rawName === name) return decodeURIComponent(rest.join("="));
  }
  return "";
}

function clipValue(value) {
  const text = typeof value === "string" ? value : JSON.stringify(value ?? null);
  if (!text || text.length <= 8000) return value ?? null;
  return `${text.slice(0, 8000)}…`;
}

function personId(req) {
  const url = new URL(req.url, "http://local");
  const fromQuery = url.searchParams.get("person") || "";
  if (PERSON.test(fromQuery)) return fromQuery;
  const fromCookie = readCookie(req, "maia_person");
  if (PERSON.test(fromCookie)) return fromCookie;
  const fromHeader = req.headers["x-maia-person"] || "";
  if (PERSON.test(fromHeader)) return fromHeader;
  const state = url.searchParams.get("state") || "";
  const pending = state ? pendingPeople.get(state) : "";
  return PERSON.test(pending) ? pending : null;
}

async function postGrant(person, reference, connections) {
  const parsed = reference ? parseUserReference(reference) : null;
  if (!reference) return;
  const body = {
    person_id: person,
    reference,
    one_user_id: reference,
    space_id: parsed?.organizationId || parsed?.projectId || null,
  };
  if (connections) {
    body.platforms = [...new Set(connections.map((row) => row.platform).filter(Boolean))];
    body.connections = connections.map((row) => ({
      platform: row.platform,
      key: row.key,
      name: row.name || row.title || row.platform,
      access: row.access ?? null,
    }));
  }
  const r = await fetch(`${MAIA}/internal/one/grant`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-maia-internal": INTERNAL },
    body: JSON.stringify(body),
  });
  if (!r.ok) console.warn("One grant save:", r.status, await r.text());
}

const userStore = {
  async saveUser(appUserId, reference) {
    await postGrant(appUserId, reference, null);
  },
  async loadUser(appUserId) {
    const r = await fetch(`${MAIA}/internal/one/grant`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-maia-internal": INTERNAL },
      body: JSON.stringify({ person_id: appUserId, lookup: true }),
    });
    if (!r.ok) return null;
    const row = await r.json();
    if (!row || row.revoked_at) return null;
    if (typeof row.reference === "string" && row.reference) return row.reference;
    if (typeof row.one_user_id === "string" && row.one_user_id.startsWith("cu_")) {
      return row.one_user_id;
    }
    return null;
  },
  async clearUser(appUserId) {
    await fetch(`${MAIA}/internal/one/grant`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-maia-internal": INTERNAL },
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
    const redirectUri = process.env.ONE_REDIRECT_URI || "http://127.0.0.1:8090/one/callback";
    process.env.ONE_REDIRECT_URI = redirectUri;
    connect = mod.createOneConnect({
      clientId: process.env.ONE_CLIENT_ID,
      clientSecret: process.env.ONE_CLIENT_SECRET,
      redirectUri,
      connectKey: process.env.ONE_CONNECT_KEY,
      returnTo: "/one/done",
      userStore,
    });
    handlers = handlersMod.createOneConnectHandlers(connect, {
      identifyUser: (req) => personId(req),
      onComplete: async ({ userId, result }) => {
        for (const [state, person] of pendingPeople) {
          if (person === userId) pendingPeople.delete(state);
        }
        if (result.outcome !== "connected") return;
        const rows = await connect.listConnections(userId);
        const reference = await userStore.loadUser(userId);
        if (reference) await postGrant(userId, reference, rows);
      },
    });
  }
} catch (err) {
  console.warn("One Connect SDK not configured:", err.message);
}

async function paramsFor(person, actionId, path, pathParams, query, body, conn) {
  let known = path || "";
  if (!known && connect && actionId) {
    try {
      const guide = await connect.getActionKnowledge(person, actionId);
      known = guide?.path || "";
    } catch {
      known = "";
    }
  }
  return fillPathParams(known, pathParams, query, body, conn);
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
      const reference = await userStore.loadUser(person);
      if (reference) await postGrant(person, reference, rows);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({
        accounts: rows.map((row) => ({
          platform: row.platform,
          key: row.key,
          name: row.name || row.title || row.platform,
          access: row.access ?? null,
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
      if (body.discover) {
        const actions = await connect.searchActions(person, platform, intent);
        const found = [];
        for (const action of (actions || []).slice(0, 3)) {
          const id = action._id || action.id;
          if (!id) continue;
          found.push({
            action_id: id,
            title: action.title || action.name || id,
            path: action.path || "",
          });
        }
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ actions: found, account: accountLogin(conn) }));
        return;
      }
      const requested = body.actionId || body.action_id;
      if (requested) {
        const pathParams = await paramsFor(
          person,
          requested,
          "",
          body.pathParams || body.path_params,
          body.query,
          body.body,
          conn,
        );
        const reply = await connect.runAction(person, {
          connectionKey: conn.key,
          actionId: requested,
          pathParams,
          query: body.query,
          body: body.body,
        });
        if (reply?.refusal === "rate_limit" || reply?.status === 429) {
          res.writeHead(429, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: "rate_limit", retry: true }));
          return;
        }
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({
          ok: Boolean(reply?.ok),
          status: reply?.status ?? null,
          refusal: reply?.refusal ?? null,
          action_id: requested,
          data: reply?.data ?? null,
        }));
        return;
      }
      const actions = await connect.searchActions(person, platform, intent);
      const action = actions[0];
      if (!action) {
        res.writeHead(404, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: `no action for ${platform}` }));
        return;
      }
      let reply;
      let last = actions[0];
      for (const candidate of actions.slice(0, 3)) {
        last = candidate;
        const pathParams = await paramsFor(
          person,
          candidate._id,
          candidate.path,
          body.pathParams || body.path_params,
          body.query,
          body.body,
          conn,
        );
        reply = await connect.runAction(person, {
          connectionKey: conn.key,
          actionId: candidate._id,
          pathParams,
          query: body.query,
          body: body.body,
        });
        if (reply.ok) break;
        if (reply.blockedByGrant || reply.refusal === "grant" || reply.refusal === "rate_limit") break;
      }
      if (reply?.refusal === "rate_limit" || reply?.status === 429) {
        res.writeHead(429, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "rate_limit", retry: true, action_id: last?._id }));
        return;
      }
      if (reply?.refusal === "reconnect_required" || /reconnect_required/.test(String(reply?.data ?? ""))) {
        res.writeHead(409, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "reconnect_required", action: last?._id }));
        return;
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({
        ok: Boolean(reply?.ok),
        status: reply?.status ?? null,
        refusal: reply?.refusal ?? null,
        action_id: last?._id || null,
        data: reply?.data ?? null,
      }));
    } catch (err) {
      const message = err.message || "pull failed";
      const reconnect = err.code === "reconnect_required" || /reconnect_required/.test(message);
      res.writeHead(reconnect ? 409 : 502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: reconnect ? "reconnect_required" : message }));
    }
    return;
  }
  if (url.pathname === "/api/one/act" && req.method === "POST") {
    if (!connect) {
      res.writeHead(503, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "one_unconfigured" }));
      return;
    }
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    let body;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString() || "{}");
    } catch {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "invalid json" }));
      return;
    }
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
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({
          error: "not_connected",
          connected: [...new Set(rows.map((row) => row.platform).filter(Boolean))],
        }));
        return;
      }
      const actionId = body.actionId || body.action_id;
      if (!actionId) {
        const intent = body.intent || "list recent records";
        let actions;
        try {
          actions = await connect.searchActions(person, platform, intent, { limit: 5 });
        } catch {
          actions = await connect.searchActions(person, platform, intent);
        }
        const decorated = [];
        for (const action of (actions || []).slice(0, 5)) {
          const id = action._id || action.id;
          if (!id) continue;
          let method = action.method || null;
          let path = action.path || "";
          if (!method) {
            try {
              const guide = await connect.getActionKnowledge(person, id);
              method = guide?.method || null;
              path = path || guide?.path || "";
            } catch {
              method = null;
            }
          }
          decorated.push({ ...action, _id: id, method, path });
        }
        const pool = rankActions(decorated, intent);
        if (!pool.length) {
          res.writeHead(200, { "content-type": "application/json" });
          res.end(JSON.stringify({ ok: false, refusal: "no_action", data: null }));
          return;
        }
        let reply;
        let last = pool[0];
        for (const candidate of pool) {
          last = candidate;
          const pathParams = await paramsFor(
            person,
            candidate._id,
            candidate.path,
            body.pathParams || body.path_params,
            body.query,
            body.body,
            conn,
          );
          reply = await connect.runAction(person, {
            connectionKey: conn.key,
            actionId: candidate._id,
            pathParams,
            query: body.query,
            body: body.body,
            encoding: body.encoding,
            headers: body.headers,
          });
          if (reply?.ok) break;
          if (reply?.blockedByGrant || reply?.refusal === "grant" || reply?.refusal === "rate_limit") break;
        }
        if (reply?.refusal === "rate_limit" || reply?.status === 429) {
          res.writeHead(429, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: "rate_limit", retry: true }));
          return;
        }
        if (reply?.refusal === "reconnect_required" || /reconnect_required/.test(String(reply?.data ?? ""))) {
          res.writeHead(409, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: "reconnect_required" }));
          return;
        }
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({
          ok: Boolean(reply?.ok),
          status: reply?.status ?? null,
          refusal: reply?.refusal ?? null,
          blocked: Boolean(reply?.blockedByGrant),
          account: accountLogin(conn),
          data: clipValue(reply?.data),
        }));
        return;
      }
      const pathParams = await paramsFor(
        person,
        actionId,
        "",
        body.pathParams || body.path_params,
        body.query,
        body.body,
        conn,
      );
      const reply = await connect.runAction(person, {
        connectionKey: conn.key,
        actionId,
        pathParams,
        query: body.query,
        body: body.body,
        encoding: body.encoding,
        headers: body.headers,
      });
      const data = clipValue(reply?.data);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({
        ok: Boolean(reply?.ok),
        status: reply?.status ?? null,
        refusal: reply?.refusal ?? null,
        blocked: Boolean(reply?.blockedByGrant),
        action_id: actionId,
        data,
      }));
    } catch (err) {
      const message = err.message || "connector failed";
      const reconnect = err.code === "reconnect_required" || /reconnect_required/.test(message);
      res.writeHead(reconnect ? 409 : 502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: reconnect ? "reconnect_required" : message }));
    }
    return;
  }
  if (url.pathname.startsWith("/api/one/")) {
    if (handlers) {
      const action = url.pathname.split("/").pop();
      req.url = url.pathname + url.search;
      if (action === "authorize") {
        const person = url.searchParams.get("person");
        if (person && PERSON.test(person)) {
          const extra = `maia_person=${encodeURIComponent(person)}; Path=${cookiePath()}; Max-Age=1800; HttpOnly; SameSite=Lax`;
          const orig = res.setHeader;
          res.setHeader = function setHeader(name, value) {
            if (String(name).toLowerCase() === "location") {
              const loc = Array.isArray(value) ? String(value[0]) : String(value);
              try {
                const state = new URL(loc).searchParams.get("state");
                if (state) pendingPeople.set(state, person);
              } catch {
                // Location is One's authorize URL; a bad URL just skips the map.
              }
            }
            if (String(name).toLowerCase() === "set-cookie") {
              const list = Array.isArray(value) ? value.slice() : [value];
              list.push(extra);
              return orig.call(this, name, list);
            }
            return orig.call(this, name, value);
          };
        }
      }
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
<p>This Maia has no <code>ONE_CLIENT_ID</code> / <code>ONE_CONNECT_KEY</code> yet, so there is nothing to authorize.</p>
<p>From <code>connect/</code>, run <code>one connect create</code>, approve Maia in the browser, and put the client secret and connect key in <code>.env</code>. Then restart Connect.</p>
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
