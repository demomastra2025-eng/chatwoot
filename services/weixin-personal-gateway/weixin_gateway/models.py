from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class ChannelConfig:
    id: int
    callback_url: str
    webhook_secret: str
    ilink_token: str | None = None
    provider_account_id: str | None = None
    display_name: str | None = None
    context_token: str | None = None
    runtime_state: dict[str, Any] = field(default_factory=dict)
    connection_state: str = "disconnected"
    lifecycle_state: str = "pending_auth"
    last_error: str | None = None
    context_tokens: dict[str, str] = field(default_factory=dict)

    @classmethod
    def from_sync_payload(cls, channel_id: int, payload: dict[str, Any]) -> "ChannelConfig":
        token = str(payload.get("ilink_token") or "").strip() or None
        callback_url = str(payload.get("callback_url") or "")
        webhook_secret = str(payload.get("webhook_secret") or "")
        if not callback_url:
            raise ValueError("callback_url is required")
        if not webhook_secret:
            raise ValueError("webhook_secret is required")

        return cls(
            id=channel_id,
            ilink_token=token,
            callback_url=callback_url,
            webhook_secret=webhook_secret,
            provider_account_id=payload.get("provider_account_id"),
            display_name=payload.get("display_name"),
            context_token=payload.get("context_token"),
            context_tokens={str(key): str(value) for key, value in dict(payload.get("context_tokens") or {}).items() if value},
            runtime_state=dict(payload.get("runtime_state") or {}),
            connection_state=payload.get("connection_state") or "disconnected",
            lifecycle_state=payload.get("lifecycle_state") or "pending_auth",
        )

    def public_channel_state(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "provider_account_id": self.provider_account_id,
            "display_name": self.display_name,
            "connection_state": self.connection_state,
            "lifecycle_state": self.lifecycle_state,
            "last_error": self.last_error,
            "runtime_state": self.runtime_state,
        }

    def credential_update_state(self) -> dict[str, Any]:
        state = self.public_channel_state()
        if self.context_token:
            state["context_token"] = self.context_token
        if self.ilink_token:
            state["ilink_token"] = self.ilink_token
        return state

    def token_for_peer(self, peer_id: str | None) -> str | None:
        if peer_id and peer_id in self.context_tokens:
            return self.context_tokens[peer_id]
        return self.context_token

    def remember_context_token(self, peer_id: str | None, context_token: str | None) -> None:
        if not peer_id or not context_token:
            return
        self.context_tokens[peer_id] = context_token
        self.context_token = context_token
