"""Page cursors for a One backfill.

A list call returns one page. The next call must ask for the following
page, and a page we already stored must not be fetched again. When the
provider has nothing further, the cursor is caught up and later syncs
read only the newest page.
"""

from __future__ import annotations

from typing import Any


def next_query(payload: Any, query: dict[str, Any], count: int) -> dict[str, Any] | None:
    """The query for the following page, or None when this page is the last."""
    if not isinstance(payload, dict):
        return None
    if _ended(payload):
        return None
    token = _token(payload)
    if token:
        key = "pageToken" if _is_page_token(payload) else "cursor"
        return {key: token}
    if count >= 20:
        page = int(str(query.get("page") or "1") or "1") + 1
        if page > 400:
            return None
        return {"page": str(page)}
    return None


def advance(state: dict[str, Any], payload: Any, ids: list[str]) -> dict[str, Any]:
    """Move the cursor after one successful page. `done` is not stored."""
    mode = state.get("mode") or "backfill"
    query = {} if mode == "caught_up" else dict(state.get("query") or {})
    last = list(state.get("last_ids") or [])
    if mode == "caught_up" or not ids:
        return {**state, "mode": "caught_up", "query": {}, "last_ids": ids, "done": True}
    if ids == last and query:
        return {**state, "mode": "caught_up", "query": {}, "last_ids": ids, "done": True}
    nxt = next_query(payload, query, len(ids))
    if not nxt:
        return {**state, "mode": "caught_up", "query": {}, "last_ids": ids, "done": True}
    return {**state, "mode": "backfill", "query": nxt, "last_ids": ids, "done": False}


def _ended(payload: dict[str, Any]) -> bool:
    if payload.get("has_more") is False:
        return True
    for key in ("paging", "pagination"):
        block = payload.get(key)
        if isinstance(block, dict) and block.get("has_more") is False:
            return True
    if "nextPageToken" in payload and not str(payload.get("nextPageToken") or "").strip():
        return True
    if "next_page_token" in payload and not str(payload.get("next_page_token") or "").strip():
        return True
    return False


def _token(payload: dict[str, Any]) -> str:
    for key in ("nextPageToken", "next_page_token", "next_cursor"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    meta = payload.get("response_metadata")
    if isinstance(meta, dict):
        value = meta.get("next_cursor")
        if isinstance(value, str) and value.strip():
            return value.strip()
    for key in ("paging", "pagination"):
        block = payload.get(key)
        if not isinstance(block, dict):
            continue
        if block.get("has_more") is False:
            return ""
        for name in ("next", "next_cursor", "cursor"):
            value = block.get(name)
            if isinstance(value, str) and value.strip() and value.strip() != "true":
                return value.strip()
    return ""


def _is_page_token(payload: dict[str, Any]) -> bool:
    return any(key in payload for key in ("nextPageToken", "next_page_token"))
