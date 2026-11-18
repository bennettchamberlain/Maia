"""One ETL job: stdin JSON {data: {person_id, platform}} -> MemoryItem rows.

One page of a connector is one call. The cursor remembers the next page,
so a later run continues the backfill instead of reading the same page.
A row with no body costs one more call, and only when we do not already
have it. A rate limit stops the run and leaves the cursor where it was.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import httpx
from dotenv import load_dotenv

from etl.adapters import normalize
from etl import one_client
from etl.paging import advance

load_dotenv(Path(__file__).resolve().parents[1] / ".env")

INTENTS = {
    "gmail": ("list recent messages", "pull recent gmail into memory"),
    "google-calendar": ("list upcoming events", "pull calendar events into memory"),
    "github": ("list user events", "pull github activity into memory"),
}
DETAIL_INTENT = "get one record by its id"
CALLS = int(os.environ.get("ONE_CALLS_PER_RUN", "40"))
GAP = float(os.environ.get("ONE_PAGE_GAP", "1"))


def main() -> int:
    job = json.load(sys.stdin)
    data = job.get("data") or {}
    platform = str(data.get("platform") or "")
    person_id = str(data.get("person_id") or "")

    base = os.environ.get("MAIA_API_URL", "http://127.0.0.1:8080").rstrip("/")
    token = str(data.get("token") or os.environ.get("MAIA_API_TOKEN") or "").strip()
    headers = {"authorization": f"Bearer {token}"} if token else {}

    result: dict[str, Any] = {"platform": platform, "upserted": 0, "calls": 0}
    try:
        if person_id:
            _sync(platform, person_id, base, headers, result)
        else:
            payload = _pull_fixture(platform)
            result["upserted"] = _store(base, headers, normalize(platform, payload))
    except Exception as exc:  # noqa: BLE001 — job runner wants the error text
        result["error"] = str(exc)
        _save_cursor(base, headers, platform, None, str(exc)[:500])
        print(json.dumps(result))
        return 1
    print(json.dumps(result))
    return 0


def _sync(
    platform: str,
    person_id: str,
    base: str,
    headers: dict[str, str],
    result: dict[str, Any],
) -> None:
    state = _load_cursor(base, headers, platform)
    calls = 0
    with httpx.Client(timeout=60) as http:
        if state.get("detail") is None:
            found = _discover(http, person_id, platform, DETAIL_INTENT)
            calls += 1
            state["detail"] = found[0]["action_id"] if found else ""
            _pause(calls)
        while calls < CALLS:
            pending = list(state.get("pending") or [])
            if pending:
                calls = _details(
                    http, person_id, platform, base, headers, state, result, calls
                )
                if state.get("stop") or state.get("pending") or state.get("done"):
                    break
                continue
            page = _act(
                http,
                person_id,
                platform,
                action_id=str(state.get("action_id") or ""),
                query={} if state.get("mode") == "caught_up" else dict(state.get("query") or {}),
                intent=INTENTS.get(platform, ("list recent records", ""))[0],
            )
            calls += 1
            result["calls"] = calls
            if page.get("retry"):
                state["stop"] = "rate_limit"
                break
            if page.get("ok") is False and page.get("data") is None:
                raise RuntimeError(page.get("error") or f"One pull failed for {platform}")
            data = page.get("data")
            if page.get("action_id"):
                state["action_id"] = page["action_id"]
            rows = normalize(platform, data)
            query = {} if state.get("mode") == "caught_up" else dict(state.get("query") or {})
            state["query"] = query
            fresh = [row for row in rows if str(row.get("body") or "").strip()]
            thin = [row for row in rows if not str(row.get("body") or "").strip()]
            result["upserted"] += _store(base, headers, fresh)
            known = _present(base, headers, platform, [str(row["source_id"]) for row in thin])
            state["pending"] = [row for row in thin if row["source_id"] not in known]
            state["page"] = data
            if not state["pending"]:
                state = _moved(state, data, [str(row["source_id"]) for row in rows])
            else:
                state["list_ids"] = [str(row["source_id"]) for row in rows]
                nxt = advance({**state, "query": query}, data, state["list_ids"])
                state["list_done"] = bool(nxt.get("done"))
                state["next_query"] = {} if nxt.get("done") else nxt.get("query") or {}
            _save_cursor(base, headers, platform, state, None)
            if state.get("done"):
                break
            if calls < CALLS:
                _pause(calls)
        result["calls"] = calls
        result["mode"] = state.get("mode") or "backfill"
        held = state.get("stop")
        _save_cursor(base, headers, platform, state, str(held) if held else None)


def _details(
    http: httpx.Client,
    person_id: str,
    platform: str,
    base: str,
    headers: dict[str, str],
    state: dict[str, Any],
    result: dict[str, Any],
    calls: int,
) -> int:
    action_id = str(state.get("detail") or "")
    pending = list(state.get("pending") or [])
    kept: list[dict[str, Any]] = []
    for row in pending:
        if calls >= CALLS:
            kept.append(row)
            continue
        source_id = str(row.get("source_id") or "")
        if not action_id:
            result["upserted"] += _store(base, headers, [row])
            continue
        page = _act(
            http,
            person_id,
            platform,
            action_id=action_id,
            query={"id": source_id},
            path_params={
                "id": source_id,
                "messageId": source_id,
                "message_id": source_id,
            },
            intent=DETAIL_INTENT,
        )
        calls += 1
        result["calls"] = calls
        if page.get("retry"):
            kept.append(row)
            kept.extend(pending[pending.index(row) + 1 :])
            state["stop"] = "rate_limit"
            break
        richer = _matching(normalize(platform, page.get("data")), source_id)
        if richer and str(richer.get("body") or "").strip():
            result["upserted"] += _store(base, headers, [richer])
        else:
            state["detail"] = ""
            action_id = ""
            result["upserted"] += _store(base, headers, [row])
        if calls < CALLS and pending[-1] is not row:
            _pause(calls)
    state["pending"] = kept
    if not kept and not state.get("stop"):
        payload = state.get("page")
        ids = list(state.get("list_ids") or [])
        if state.get("list_done"):
            state["mode"] = "caught_up"
            state["query"] = {}
            state["done"] = True
        elif state.get("next_query"):
            state["mode"] = "backfill"
            state["query"] = state["next_query"]
            state["done"] = False
            state["last_ids"] = ids
        else:
            state = _moved(state, payload, ids)
    return calls


def _moved(state: dict[str, Any], payload: Any, ids: list[str]) -> dict[str, Any]:
    moved = advance(state, payload, ids)
    done = bool(moved.pop("done", False))
    moved["list_done"] = done
    moved["done"] = done
    moved["page"] = None
    return moved


def _matching(rows: list[dict[str, Any]], source_id: str) -> dict[str, Any] | None:
    for row in rows:
        if str(row.get("source_id") or "") == source_id:
            return row
    return rows[0] if len(rows) == 1 else None


def _act(
    http: httpx.Client,
    person_id: str,
    platform: str,
    *,
    action_id: str,
    query: dict[str, Any] | None,
    intent: str,
    path_params: dict[str, str] | None = None,
) -> dict[str, Any]:
    connect = (os.environ.get("CONNECT_URL") or "http://127.0.0.1:8788").rstrip("/")
    try:
        response = http.post(
            f"{connect}/api/one/pull",
            json={
                "person": person_id,
                "platform": platform,
                "intent": intent,
                "actionId": action_id or None,
                "query": query or None,
                "pathParams": path_params or None,
            },
        )
    except httpx.HTTPError as exc:
        raise RuntimeError(f"One Connect sidecar is not reachable at {connect}") from exc
    if response.status_code == 429:
        return {"retry": True, "ok": False, "data": None}
    try:
        body = response.json()
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            response.text[:300] or f"One pull failed ({response.status_code})"
        ) from exc
    if not isinstance(body, dict):
        return {"ok": True, "data": body, "action_id": action_id}
    if body.get("error") == "rate_limit" or body.get("retry") is True:
        return {"retry": True, "ok": False, "data": None}
    if response.status_code >= 400 or body.get("error"):
        detail = str(body.get("error") or response.status_code)
        if detail == "reconnect_required":
            raise RuntimeError("One grant needs a reconnect")
        raise RuntimeError(detail)
    if "data" in body or "action_id" in body:
        return body
    return {"ok": True, "data": body, "action_id": action_id}


def _discover(
    http: httpx.Client, person_id: str, platform: str, intent: str
) -> list[dict[str, Any]]:
    connect = (os.environ.get("CONNECT_URL") or "http://127.0.0.1:8788").rstrip("/")
    try:
        response = http.post(
            f"{connect}/api/one/pull",
            json={
                "person": person_id,
                "platform": platform,
                "intent": intent,
                "discover": True,
            },
        )
    except httpx.HTTPError as exc:
        raise RuntimeError(f"One Connect sidecar is not reachable at {connect}") from exc
    if response.status_code >= 400:
        return []
    body = response.json()
    actions = body.get("actions") if isinstance(body, dict) else None
    return [row for row in actions or [] if isinstance(row, dict) and row.get("action_id")]


def _store(base: str, headers: dict[str, str], rows: list[dict[str, Any]]) -> int:
    kept = 0
    with httpx.Client(timeout=30) as http:
        for item in rows:
            response = http.post(f"{base}/memory", json=item, headers=headers)
            response.raise_for_status()
            kept += 1
    return kept


def _present(base: str, headers: dict[str, str], platform: str, ids: list[str]) -> set[str]:
    if not ids:
        return set()
    try:
        response = httpx.post(
            f"{base}/memory/present",
            json={"source": f"one:{platform}", "source_ids": ids},
            headers=headers,
            timeout=30,
        )
    except httpx.HTTPError:
        return set()
    if response.status_code >= 400:
        return set()
    body = response.json()
    found = body.get("ids") if isinstance(body, dict) else None
    return {str(item) for item in found or []}


def _load_cursor(base: str, headers: dict[str, str], platform: str) -> dict[str, Any]:
    try:
        response = httpx.get(f"{base}/one/cursors", headers=headers, timeout=30)
        response.raise_for_status()
    except httpx.HTTPError:
        return {}
    rows = response.json()
    if isinstance(rows, dict):
        rows = rows.get("data") or rows.get("rows") or []
    if not isinstance(rows, list):
        return {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        if row.get("platform") != platform or row.get("endpoint") != "sync":
            continue
        cursor = row.get("cursor")
        if isinstance(cursor, str):
            try:
                cursor = json.loads(cursor)
            except json.JSONDecodeError:
                cursor = None
        return dict(cursor) if isinstance(cursor, dict) else {}
    return {}


def _save_cursor(
    base: str,
    headers: dict[str, str],
    platform: str,
    state: dict[str, Any] | None,
    error: str | None,
) -> None:
    if not platform:
        return
    stored = dict(state or {})
    for key in ("done", "stop", "page"):
        stored.pop(key, None)
    try:
        httpx.put(
            f"{base}/one/cursors",
            json={
                "platform": platform,
                "endpoint": "sync",
                "cursor": stored or None,
                "last_error": error,
            },
            headers=headers,
            timeout=15,
        )
    except httpx.HTTPError:
        pass


def _pause(calls: int) -> None:
    if calls > 0 and GAP > 0:
        time.sleep(GAP)


def _pull_fixture(platform: str) -> object:
    fixture = os.environ.get("MAIA_ETL_FIXTURE")
    if fixture:
        data = json.loads(Path(fixture).read_text())
        if isinstance(data, dict) and platform in data:
            return data[platform]
        return data
    if not os.environ.get("ONE_SECRET") and not os.environ.get("ONE_CONNECTION_KEYS"):
        raise RuntimeError("ONE_SECRET not set; connect One or set MAIA_ETL_FIXTURE")
    intent, task = INTENTS.get(
        platform,
        ("list recent records", f"pull recent {platform} records into memory"),
    )
    model = os.environ.get("PARASAIL_MODEL", "parasail-glm-53-flash")
    conns = [
        c
        for c in one_client.list_connections(platform)
        if str(c.get("platform") or "") == platform
    ]
    if not conns:
        raise RuntimeError(f"no One connection for {platform}")
    key = conns[0].get("key") or conns[0].get("connectionKey")
    found = one_client.find_action(platform, intent, task, model)
    action_id = found.get("actionId") or found.get("action_id")
    if not action_id or not key:
        raise RuntimeError(f"could not resolve {platform} action")
    return one_client.execute(platform, action_id, str(key))


if __name__ == "__main__":
    raise SystemExit(main())
