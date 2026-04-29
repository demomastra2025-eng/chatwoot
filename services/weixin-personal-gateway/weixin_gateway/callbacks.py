from __future__ import annotations

import json
import hashlib
import time
import uuid
from dataclasses import dataclass
from typing import Any
from urllib import request

from .models import ChannelConfig
from .security import jwt_hs256


@dataclass(frozen=True)
class CallbackRequest:
    url: str
    headers: dict[str, str]
    body: str

    def json_body(self) -> dict[str, Any]:
        return json.loads(self.body)


def _text_from_item_list(raw: dict[str, Any]) -> str:
    items = raw.get("item_list") or raw.get("items") or []
    if not isinstance(items, list):
        return ""

    chunks: list[str] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        text_item = item.get("text_item") or item.get("textItem") or {}
        if isinstance(text_item, dict):
            text = text_item.get("text") or text_item.get("content")
            if text:
                chunks.append(str(text))
        elif isinstance(text_item, str):
            chunks.append(text_item)
    return "\n".join(chunks)


def normalize_message(raw: dict[str, Any]) -> dict[str, Any]:
    message_id = raw.get("message_id") or raw.get("id") or raw.get("client_id") or raw.get("msg_id")
    sender_id = raw.get("sender_id") or raw.get("from_user_id") or raw.get("peer_user_id") or raw.get("chat_id")
    chat_id = raw.get("chat_id") or raw.get("room_id") or sender_id
    text = raw.get("text") or raw.get("content") or _text_from_item_list(raw) or ""
    if isinstance(text, dict):
        text = text.get("text") or text.get("content") or ""

    return {
        "message_id": message_id,
        "sender_id": sender_id,
        "sender_name": raw.get("sender_name") or raw.get("nickname"),
        "chat_id": chat_id,
        "recipient_id": raw.get("to_user_id") or raw.get("recipient_id"),
        "message_type": raw.get("message_type"),
        "context_token": raw.get("context_token"),
        "text": str(text),
    }


def build_callback(channel: ChannelConfig, *, event: str, data: dict[str, Any]) -> CallbackRequest:
    body = json.dumps({"event": event, "data": data}, ensure_ascii=False, separators=(",", ":"))
    token = jwt_hs256(
        {
            "iss": "onelink-weixin-personal-gateway",
            "channel_id": channel.id,
            "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest(),
            "jti": uuid.uuid4().hex,
            "exp": int(time.time()) + 300,
        },
        channel.webhook_secret,
    )
    return CallbackRequest(
        url=channel.callback_url,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        body=body,
    )


def post_callback(callback: CallbackRequest, *, timeout: float = 15.0) -> tuple[int, str]:
    req = request.Request(
        callback.url,
        data=callback.body.encode("utf-8"),
        headers=callback.headers,
        method="POST",
    )
    with request.urlopen(req, timeout=timeout) as response:
        return response.status, response.read().decode("utf-8")
