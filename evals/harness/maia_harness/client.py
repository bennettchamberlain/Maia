"""OpenRouter chat completions. The API key stays in the request header."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from typing import Any

from maia_harness.agent import TOOLS
from maia_harness.distill import redact


class ApiError(Exception):
    def __init__(self, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.retryable = retryable


def normalize_assistant(message: dict[str, Any]) -> dict[str, Any]:
    content = message.get("content")
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict) and part.get("type") in {"text", "output_text"}:
                parts.append(str(part.get("text") or ""))
        content = "".join(parts) if parts else None
    elif content is not None and not isinstance(content, str):
        content = str(content)
    assistant: dict[str, Any] = {"role": "assistant", "content": content}
    calls: list[dict[str, Any]] = []
    for index, call in enumerate(message.get("tool_calls") or []):
        function = call.get("function") or {}
        arguments = function.get("arguments")
        if not isinstance(arguments, str):
            arguments = json.dumps(arguments or {}, ensure_ascii=False)
        calls.append(
            {
                "id": call.get("id") or f"call_{index}",
                "type": "function",
                "function": {
                    "name": function.get("name") or "",
                    "arguments": arguments,
                },
            }
        )
    if calls:
        assistant["tool_calls"] = calls
    reasoning = message.get("reasoning_content") or message.get("reasoning")
    if isinstance(reasoning, str) and reasoning.strip():
        assistant["reasoning"] = reasoning
    return assistant


class OpenRouterClient:
    def __init__(
        self,
        *,
        api_key: str,
        model: str,
        base_url: str,
        max_tokens: int,
        timeout: float,
    ) -> None:
        self.api_key = api_key
        self.model = model
        self.max_tokens = max_tokens
        self.timeout = timeout
        self.url = base_url.rstrip("/") + "/chat/completions"

    def complete(
        self,
        messages: list[dict[str, Any]],
        *,
        tool_choice: str = "auto",
        max_tokens: int | None = None,
    ) -> dict[str, Any]:
        last: Exception | None = None
        for attempt in range(3):
            try:
                return self._once(messages, tool_choice, max_tokens or self.max_tokens)
            except ApiError as exc:
                if not exc.retryable:
                    raise
                last = exc
            except (TimeoutError, urllib.error.URLError) as exc:
                last = ApiError(
                    redact(f"OpenRouter request failed: {exc}"), retryable=True
                )
            if attempt < 2:
                time.sleep(min(8, 2**attempt))
        raise ApiError(redact(str(last) if last else "OpenRouter request failed"))

    def _once(
        self,
        messages: list[dict[str, Any]],
        tool_choice: str,
        max_tokens: int,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": 0,
            "stream": False,
            "provider": {"allow_fallbacks": False},
        }
        if tool_choice != "none":
            body["tools"] = TOOLS
            body["tool_choice"] = "auto"
        data = json.dumps(body).encode("utf-8")
        request = urllib.request.Request(
            self.url,
            data=data,
            headers={
                "Authorization": "Bearer " + self.api_key,
                "Content-Type": "application/json",
                "HTTP-Referer": "https://github.com/bennettchamberlain/Maia",
                "X-Title": "Maia harness distillation",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:500]
            retryable = exc.code in {408, 429, 500, 502, 503, 504}
            raise ApiError(
                redact(f"OpenRouter HTTP {exc.code}: {detail}"),
                retryable=retryable,
            ) from None
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ApiError(
                f"OpenRouter returned non-JSON: {exc}", retryable=True
            ) from None
        if (
            isinstance(payload, dict)
            and payload.get("error")
            and "choices" not in payload
        ):
            err = payload["error"]
            text = err.get("message") if isinstance(err, dict) else str(err)
            raise ApiError(redact(f"OpenRouter error: {text}")[:500])
        try:
            message = payload["choices"][0]["message"]
        except (KeyError, IndexError, TypeError):
            raise ApiError(
                redact(f"OpenRouter response missing choices: {raw[:300]}")
            ) from None
        if not isinstance(message, dict):
            raise ApiError("OpenRouter message was not an object")
        return normalize_assistant(message)
