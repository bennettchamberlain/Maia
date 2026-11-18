const WRITE = /\b(create|send|delete|update|post|write|comment|close|merge|push)\b/i;

function methodOf(action) {
  return String(action?.method || "GET").toUpperCase();
}

/**
 * Which One actions a chat call may run on its own.
 * A read stays a read unless the person asked to change something.
 */
export function rankActions(actions, intent) {
  const list = Array.isArray(actions) ? actions : [];
  const write = WRITE.test(intent || "");
  const reads = list.filter((action) => {
    const method = methodOf(action);
    return method === "GET" || method === "HEAD";
  });
  const pool = write ? list : reads.length ? reads : list;
  return pool.slice(0, 3);
}
