/** A login-shaped token from a One connection or a model field. */
export function cleanLogin(value) {
  const text = String(value ?? "")
    .trim()
    .replace(/^@/, "")
    .replace(/\/+$/, "");
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(text)) return "";
  return text;
}

/** The account the connection already is. A display name with a space is not a login. */
export function accountLogin(conn) {
  if (!conn || typeof conn !== "object") return "";
  for (const key of ["login", "username", "handle", "account"]) {
    const value = cleanLogin(conn[key]);
    if (value) return value;
  }
  for (const key of ["name", "title"]) {
    const raw = String(conn[key] ?? "").trim();
    if (!raw || /\s/.test(raw)) continue;
    const value = cleanLogin(raw);
    if (value) return value;
  }
  return "";
}

const IDENTITY = new Set(["username", "user", "login", "owner"]);

function bag(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

/**
 * Fills `{{placeholders}}` before One runs the action.
 * A value the model put on the query still counts, and a missing
 * username comes from the connection.
 */
export function fillPathParams(path, pathParams, query, body, conn) {
  const params = { ...bag(pathParams) };
  const sources = [params, bag(query), bag(body)];
  const names = [...String(path || "").matchAll(/\{\{\s*([^}]+?)\s*\}\}/g)].map(
    (match) => match[1].trim(),
  );
  for (const key of names) {
    if (cleanLogin(params[key]) || String(params[key] ?? "").trim()) {
      const cleaned = cleanLogin(params[key]);
      if (cleaned) params[key] = cleaned;
      continue;
    }
    for (const source of sources) {
      const cleaned = cleanLogin(source[key]);
      if (cleaned) {
        params[key] = cleaned;
        break;
      }
    }
    if (!String(params[key] ?? "").trim() && IDENTITY.has(key)) {
      const login = accountLogin(conn);
      if (login) params[key] = login;
    }
  }
  return params;
}
