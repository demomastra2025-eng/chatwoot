"""Capability-scoped control client for the Node-owned Janus leg."""

from __future__ import annotations

from typing import Any

import httpx

from app.api.models import RuntimeControl
from app.clients.onelink import OnelinkApiError


class RuntimeControlClient:
    def __init__(self, capability: RuntimeControl, *, timeout_seconds: float = 35.0):
        self._url = str(capability.control_url)
        self._token = capability.token.get_secret_value()
        self._timeout = timeout_seconds

    async def execute(self, result: dict[str, Any]) -> dict[str, Any] | None:
        action = str(result.get("action") or "").strip().lower()
        if action not in {"transfer", "end_call"}:
            return None
        payload = {
            "action": action,
            "operator_agent_aor": result.get("operator_agent_aor"),
            "reason": result.get("reason"),
        }
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            try:
                response = await client.post(
                    self._url,
                    json={key: value for key, value in payload.items() if value is not None},
                    headers={"authorization": f"Bearer {self._token}"},
                )
            except (httpx.TimeoutException, httpx.TransportError) as error:
                raise OnelinkApiError(
                    type(error).__name__,
                    code="runtime_control_transport_error",
                ) from error
        if not response.is_success:
            raise OnelinkApiError(
                f"Runtime control failed with HTTP {response.status_code}",
                status=response.status_code,
                code="runtime_control_failed",
            )
        try:
            parsed = response.json()
        except ValueError as error:
            raise OnelinkApiError(
                "Runtime control returned invalid JSON",
                code="runtime_control_invalid_json",
            ) from error
        return parsed if isinstance(parsed, dict) else {"status": "accepted"}
