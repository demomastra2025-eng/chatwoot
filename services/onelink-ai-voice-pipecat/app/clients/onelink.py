"""OneLink Rails control/data-plane client."""

from __future__ import annotations

import asyncio
import re
from dataclasses import asdict, dataclass
from typing import Any
from urllib.parse import quote, urlsplit, urlunsplit

import httpx

_SECRET_KEY = re.compile(r"(?:authorization|token|secret|password|api[_-]?key)", re.IGNORECASE)
_URL_KEY = re.compile(r"(?:stream_url|recording_url|capability_url)", re.IGNORECASE)
_BEARER = re.compile(r"Bearer\s+\S+", re.IGNORECASE)


class OnelinkApiError(RuntimeError):
    """Safe API failure that never includes response bodies or credentials."""

    def __init__(self, message: str, *, status: int = 0, code: str = "request_failed"):
        super().__init__(_BEARER.sub("Bearer [redacted]", str(message))[:240])
        self.status = status
        self.code = code


@dataclass(frozen=True, slots=True)
class Correlation:
    """Tenant and runtime identity carried through every callback."""

    call_ref: str
    runtime_session_id: str
    account_id: str | int | None = None
    conversation_id: str | int | None = None
    call_session_id: str | int | None = None
    inbox_id: str | int | None = None
    runtime_engine: str = "pipecat"

    def payload(self) -> dict[str, Any]:
        return {key: value for key, value in asdict(self).items() if value is not None}


class OnelinkClient:
    """Bounded async client for existing Rails AI Voice endpoints."""

    VOICE_CAPABILITIES = "callback_handoff_v1"

    def __init__(
        self,
        *,
        base_url: str,
        token: str,
        timeout_seconds: float = 5.0,
        max_retries: int = 2,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        self._token = token.strip()
        self._max_retries = max(0, max_retries)
        self._client = httpx.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=httpx.Timeout(timeout_seconds),
            transport=transport,
            headers={"accept": "application/json"},
        )

    async def __aenter__(self) -> OnelinkClient:
        return self

    async def __aexit__(self, *_args: object) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        await self._client.aclose()

    async def get_context(self, payload: dict[str, Any]) -> dict[str, Any]:
        return await self._request(
            "/internal/voice/ai/context",
            body=payload,
            headers={"x-onelink-voice-capabilities": self.VOICE_CAPABILITIES},
            retryable=True,
        )

    async def send_transcript(
        self,
        correlation: Correlation,
        *,
        items: list[dict[str, Any]],
        final: bool = False,
    ) -> dict[str, Any]:
        return await self._request(
            "/internal/voice/ai/transcript",
            body={**correlation.payload(), "final": final, "items": items},
            retryable=True,
        )

    async def send_control(
        self,
        correlation: Correlation,
        *,
        action: str,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return await self._request(
            "/internal/voice/ai/control",
            body={**correlation.payload(), "action": action, "metadata": metadata or {}},
            retryable=False,
        )

    async def send_heartbeat(self, correlation: Correlation) -> dict[str, Any]:
        return await self._request(
            "/internal/voice/ai/heartbeat",
            body=correlation.payload(),
            retryable=True,
        )

    async def send_event(
        self,
        correlation: Correlation,
        *,
        event_type: str,
        payload: dict[str, Any],
        event_id: str,
        sequence: int,
        attempt: int = 1,
    ) -> dict[str, Any]:
        body = {
            **correlation.payload(),
            "event_id": event_id,
            "event_key": event_id,
            "event_seq": sequence,
            "event_type": event_type,
            "payload": payload,
        }
        return await self._request(
            "/internal/voice/ai/event",
            body=body,
            headers=_event_headers(event_id, attempt),
            retryable=True,
        )

    async def finalize_call(
        self,
        correlation: Correlation,
        *,
        payload: dict[str, Any],
        event_id: str,
        attempt: int = 1,
    ) -> dict[str, Any]:
        return await self._request(
            "/internal/voice/ai/finalize",
            body={**correlation.payload(), **payload, "event_id": event_id, "event_key": event_id},
            headers=_event_headers(event_id, attempt),
            retryable=True,
        )

    async def call_tool(
        self,
        correlation: Correlation,
        name: str,
        arguments: dict[str, Any],
        *,
        tool_call_id: str,
        timeout_seconds: float,
    ) -> Any:
        result = await self._request(
            f"/internal/voice/ai/tools/{quote(name.strip(), safe='')}",
            body={
                **correlation.payload(),
                "arguments": arguments,
                "request_id": tool_call_id,
                "tool_call_id": tool_call_id,
                "idempotency_key": tool_call_id,
            },
            retryable=False,
            timeout_seconds=timeout_seconds,
        )
        return result.get("result", result)

    async def recording_stored(
        self,
        correlation: Correlation,
        *,
        payload: dict[str, Any],
        event_id: str,
    ) -> dict[str, Any]:
        return await self._request(
            "/internal/voice/recordings/stored",
            body={**correlation.payload(), **payload, "event_id": event_id, "event_key": event_id},
            headers=_event_headers(event_id, 1),
            retryable=True,
        )

    async def _request(
        self,
        path: str,
        *,
        body: dict[str, Any],
        headers: dict[str, str] | None = None,
        retryable: bool,
        timeout_seconds: float | None = None,
    ) -> dict[str, Any]:
        request_headers = {"content-type": "application/json", **(headers or {})}
        if self._token:
            request_headers["authorization"] = f"Bearer {self._token}"
        attempts = self._max_retries + 1 if retryable else 1

        for attempt in range(1, attempts + 1):
            attempt_headers = dict(request_headers)
            if "x-event-attempt" in attempt_headers:
                initial_attempt = int(attempt_headers["x-event-attempt"])
                attempt_headers["x-event-attempt"] = str(initial_attempt + attempt - 1)
            try:
                response = await self._client.post(
                    path,
                    json=body,
                    headers=attempt_headers,
                    timeout=timeout_seconds,
                )
            except (httpx.TimeoutException, httpx.TransportError) as error:
                if attempt < attempts:
                    await asyncio.sleep(0.05 * (2 ** (attempt - 1)))
                    continue
                raise OnelinkApiError(type(error).__name__, code="transport_error") from error

            if response.status_code in {408, 429} or response.status_code >= 500:
                if attempt < attempts:
                    await asyncio.sleep(0.05 * (2 ** (attempt - 1)))
                    continue
            if not response.is_success:
                code = "http_error"
                try:
                    parsed = response.json()
                    if isinstance(parsed, dict):
                        code = str(parsed.get("error") or parsed.get("code") or code)[:80]
                except ValueError:
                    pass
                raise OnelinkApiError(
                    f"OneLink callback failed with HTTP {response.status_code}",
                    status=response.status_code,
                    code=code,
                )
            if not response.content:
                return {}
            try:
                parsed = response.json()
            except ValueError as error:
                raise OnelinkApiError(
                    "OneLink callback returned invalid JSON",
                    status=response.status_code,
                    code="invalid_json",
                ) from error
            if not isinstance(parsed, dict):
                raise OnelinkApiError(
                    "OneLink callback returned invalid contract",
                    status=response.status_code,
                    code="invalid_contract",
                )
            return parsed

        raise AssertionError("unreachable")


def _event_headers(event_id: str, attempt: int) -> dict[str, str]:
    return {
        "x-event-id": event_id,
        "x-idempotency-key": event_id,
        "x-event-attempt": str(attempt),
    }


def redact(value: Any, *, key: str = "") -> Any:
    """Return a log-safe copy of nested payloads."""
    if _SECRET_KEY.search(key):
        return "[redacted]"
    if isinstance(value, dict):
        return {
            str(item_key): redact(item_value, key=str(item_key))
            for item_key, item_value in value.items()
        }
    if isinstance(value, list):
        return [redact(item, key=key) for item in value]
    if isinstance(value, tuple):
        return tuple(redact(item, key=key) for item in value)
    if isinstance(value, str):
        if _URL_KEY.search(key):
            parts = urlsplit(value)
            return urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
        return _BEARER.sub("Bearer [redacted]", value)
    return value
