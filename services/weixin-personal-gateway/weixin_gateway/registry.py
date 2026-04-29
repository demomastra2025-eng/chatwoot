from __future__ import annotations

import json
import logging
import threading
import time
import re
from typing import Any, Callable

from .callbacks import CallbackRequest, build_callback, normalize_message, post_callback
from .ilink import IlinkClient, IlinkRequest, HttpIlinkTransport, split_text_for_weixin
from .models import ChannelConfig

CallbackSender = Callable[[CallbackRequest], Any]
LOGGER = logging.getLogger(__name__)
QR_RESPONSE_SHAPE_MAX_DEPTH = 4
SENSITIVE_ERROR_PATTERN = re.compile(
    r"(authorization|bearer|token|secret|password|api[_-]?key|connection[_-]?string)([\"'\s:=]+)([^\"'\s,}]+)",
    re.IGNORECASE,
)


class ChannelRegistry:
    def __init__(
        self,
        *,
        client: IlinkClient | None = None,
        transport: Any | None = None,
        callback_sender: CallbackSender | None = None,
        auto_start: bool = False,
    ) -> None:
        self._channels: dict[int, ChannelConfig] = {}
        self._client = client or IlinkClient()
        self._transport = transport or HttpIlinkTransport()
        self._callback_sender = callback_sender or post_callback
        self._auto_start = auto_start
        self._workers: dict[int, tuple[threading.Event, threading.Thread]] = {}
        self._qr_watchers: dict[int, tuple[threading.Event, threading.Thread]] = {}
        self._lock = threading.RLock()

    def sync(self, channel_id: int, payload: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            channel = ChannelConfig.from_sync_payload(channel_id, payload)
            existing = self._channels.get(channel_id)
            if existing:
                channel.connection_state = existing.connection_state
                channel.lifecycle_state = existing.lifecycle_state
                channel.last_error = existing.last_error
                channel.runtime_state = {**existing.runtime_state, **channel.runtime_state}
                channel.context_tokens = {**existing.context_tokens, **channel.context_tokens}
                channel.ilink_token = channel.ilink_token or existing.ilink_token
                channel.context_token = channel.context_token or existing.context_token
                channel.provider_account_id = channel.provider_account_id or existing.provider_account_id
                channel.display_name = channel.display_name or existing.display_name
            self._channels[channel_id] = channel

        if self._auto_start and channel.ilink_token:
            self._start_worker(channel_id)
        return {"channel": channel.public_channel_state()}

    def get(self, channel_id: int) -> ChannelConfig:
        try:
            return self._channels[channel_id]
        except KeyError as exc:
            raise KeyError(f"Channel {channel_id} is not synced") from exc

    def delete(self, channel_id: int) -> dict[str, Any]:
        self._stop_worker(channel_id)
        self._stop_qr_watcher(channel_id)
        with self._lock:
            self._channels.pop(channel_id, None)
        return {"deleted": True}

    def diagnostics(self, channel_id: int) -> dict[str, Any]:
        channel = self.get(channel_id)
        return {
            "channel": channel.public_channel_state(),
            "synced": True,
            "worker_running": self._worker_running(channel_id),
            "qr_watcher_running": self._qr_watcher_running(channel_id),
            "secrets_present": {
                "ilink_token": bool(channel.ilink_token),
                "webhook_secret": bool(channel.webhook_secret),
            },
        }

    def apply_runtime_update(self, channel_id: int, **attrs: Any) -> dict[str, Any]:
        channel = self.get(channel_id)
        for key, value in attrs.items():
            if value is not None and hasattr(channel, key):
                if key == "last_error":
                    value = _redact_error_message(str(value))
                setattr(channel, key, value)
        return {"channel": channel.public_channel_state()}

    def request_qr(self, channel_id: int, qr_url: str | None = None) -> dict[str, Any]:
        channel = self.get(channel_id)
        response: dict[str, Any] = {}
        if qr_url:
            qr_state = {"qr_login_url": qr_url, "qr_login_state": "ready"}
        else:
            response = self._execute(self._client.get_bot_qr_request())
            qr_state = self._qr_state_from_response(response)
            if not _has_renderable_qr_payload(qr_state):
                error_message = "iLink QR response did not include a renderable QR payload"
                self._mark_qr_request_error(channel, error_message)
                _log_qr_response_shape(channel_id, response)
                raise ValueError(error_message)

        channel.connection_state = "connecting"
        channel.lifecycle_state = "qr_ready"
        channel.last_error = None
        channel.runtime_state = {
            **channel.runtime_state,
            **qr_state,
            "qr_login_requested_at": _now_epoch(),
        }

        self._apply_login_payload(channel, response)
        qrcode = channel.runtime_state.get("qr_login_ticket") or channel.runtime_state.get("qrcode")
        if self._auto_start and qrcode and not channel.ilink_token:
            self._start_qr_watcher(channel_id, str(qrcode))
        if self._auto_start and channel.ilink_token:
            self._start_worker(channel_id)

        return {"channel": channel.public_channel_state()}

    def reconnect(self, channel_id: int) -> dict[str, Any]:
        channel = self.get(channel_id)
        channel.connection_state = "connecting"
        channel.lifecycle_state = "pending_auth" if not channel.ilink_token else "connected"
        channel.last_error = None
        if self._auto_start and channel.ilink_token:
            self._start_worker(channel_id)
        return {"channel": channel.public_channel_state()}

    def disconnect(self, channel_id: int) -> dict[str, Any]:
        self._stop_worker(channel_id)
        self._stop_qr_watcher(channel_id)
        channel = self.get(channel_id)
        channel.connection_state = "disconnected"
        channel.lifecycle_state = "disconnected"
        channel.runtime_state = {**channel.runtime_state, "poller_state": "stopped", "poller_stopped_at": _now_epoch()}
        return {"channel": channel.public_channel_state()}

    def send_message(self, channel_id: int, payload: dict[str, Any]) -> dict[str, Any]:
        channel = self.get(channel_id)
        if not channel.ilink_token:
            raise ValueError("ilink_token is required")

        attachments = payload.get("attachments") or []
        if attachments:
            raise ValueError("Weixin media sending is not implemented in this gateway yet")

        recipient_id = str(payload.get("recipient_id") or payload.get("chat_id") or "")
        if not recipient_id:
            raise ValueError("recipient_id is required")
        text = str(payload.get("text") or "")
        context_token = payload.get("context_token") or channel.token_for_peer(recipient_id)
        chunks = split_text_for_weixin(text)
        message_ids: list[str] = []
        for index, chunk in enumerate(chunks):
            client_id = payload.get("client_id") or f"weixin-out-{channel_id}-{int(time.time() * 1000)}-{index}"
            response = self._execute(
                self._client.send_text_message_request(
                    token=channel.ilink_token,
                    to_user_id=recipient_id,
                    text=chunk,
                    context_token=context_token,
                    client_id=client_id,
                )
            )
            message_ids.append(str(_find_first(response, "message_id", "msg_id", "client_id") or client_id))

        return {"message_id": message_ids[0], "message_ids": message_ids, "context_token": context_token}

    def poll_once(self, channel_id: int) -> dict[str, Any]:
        channel = self.get(channel_id)
        if not channel.ilink_token:
            raise ValueError("ilink_token is required")

        sync_buf = str(channel.runtime_state.get("last_update_id") or channel.runtime_state.get("get_updates_buf") or "")
        response = self._execute(self._client.get_updates_request(token=channel.ilink_token, sync_buf=sync_buf))
        next_buf = _find_first(response, "get_updates_buf", "next_get_updates_buf", "sync_buf", "buf")
        if next_buf is not None:
            channel.runtime_state = {**channel.runtime_state, "last_update_id": str(next_buf), "get_updates_buf": str(next_buf)}

        processed = 0
        for raw in _extract_messages(response):
            normalized = normalize_message(raw)
            message_id = normalized.get("message_id")
            if not message_id or self._seen_message(channel, str(message_id)):
                continue
            self._remember_message(channel, str(message_id))
            peer_id = normalized.get("chat_id") or normalized.get("sender_id")
            channel.remember_context_token(peer_id, normalized.get("context_token"))
            self._callback_sender(build_callback(channel, event="message.created", data=normalized))
            processed += 1

        channel.connection_state = "connected"
        channel.lifecycle_state = "connected"
        channel.runtime_state = {**channel.runtime_state, "poller_state": "running", "poller_started_at": channel.runtime_state.get("poller_started_at") or _now_epoch()}
        return {"processed": processed, "channel": channel.public_channel_state()}

    def _execute(self, request: IlinkRequest) -> dict[str, Any]:
        response = self._transport.execute(request)
        if response is None:
            return {}
        if not isinstance(response, dict):
            raise ValueError("iLink response must be a JSON object")
        return response

    def _start_worker(self, channel_id: int) -> None:
        if self._worker_running(channel_id):
            return
        stop_event = threading.Event()
        thread = threading.Thread(target=self._worker_loop, args=(channel_id, stop_event), daemon=True)
        self._workers[channel_id] = (stop_event, thread)
        thread.start()

    def _worker_loop(self, channel_id: int, stop_event: threading.Event) -> None:
        errors = 0
        while not stop_event.is_set():
            try:
                self.poll_once(channel_id)
                errors = 0
            except Exception as exc:  # pragma: no cover - exercised by integration/runtime
                errors += 1
                self._mark_runtime_error(channel_id, exc)
            stop_event.wait(30 if errors >= 3 else 0.1)

    def _stop_worker(self, channel_id: int) -> None:
        worker = self._workers.pop(channel_id, None)
        if worker:
            worker[0].set()

    def _worker_running(self, channel_id: int) -> bool:
        worker = self._workers.get(channel_id)
        return bool(worker and worker[1].is_alive())

    def _start_qr_watcher(self, channel_id: int, qrcode: str) -> None:
        if self._qr_watcher_running(channel_id):
            return
        stop_event = threading.Event()
        thread = threading.Thread(target=self._qr_watcher_loop, args=(channel_id, qrcode, stop_event), daemon=True)
        self._qr_watchers[channel_id] = (stop_event, thread)
        thread.start()

    def _qr_watcher_loop(self, channel_id: int, qrcode: str, stop_event: threading.Event) -> None:
        while not stop_event.is_set():
            try:
                channel = self.get(channel_id)
                response = self._execute(self._client.get_qr_status_request(qrcode=qrcode))
                self._apply_login_payload(channel, response)
                if channel.ilink_token:
                    channel.connection_state = "connected"
                    channel.lifecycle_state = "connected"
                    channel.runtime_state = {**channel.runtime_state, "qr_login_state": "confirmed", "qr_login_completed_at": _now_epoch()}
                    self._callback_sender(build_callback(channel, event="runtime.updated", data=channel.credential_update_state()))
                    if self._auto_start:
                        self._start_worker(channel_id)
                    return
                status = str(_find_first(response, "status", "state", "qr_login_state") or "").lower()
                if status in {"expired", "qr_expired"}:
                    channel.lifecycle_state = "qr_expired"
                    channel.runtime_state = {**channel.runtime_state, "qr_login_state": "expired", "qr_login_expired_at": _now_epoch()}
                    self._callback_sender(build_callback(channel, event="runtime.updated", data=channel.public_channel_state()))
                    return
            except Exception as exc:  # pragma: no cover - runtime safety
                self._mark_runtime_error(channel_id, exc)
            stop_event.wait(2)

    def _stop_qr_watcher(self, channel_id: int) -> None:
        watcher = self._qr_watchers.pop(channel_id, None)
        if watcher:
            watcher[0].set()

    def _qr_watcher_running(self, channel_id: int) -> bool:
        watcher = self._qr_watchers.get(channel_id)
        return bool(watcher and watcher[1].is_alive())

    def _mark_runtime_error(self, channel_id: int, error: Exception) -> None:
        try:
            channel = self.get(channel_id)
        except KeyError:
            return
        channel.connection_state = "failed"
        channel.lifecycle_state = "failed"
        channel.last_error = _redact_error_message(str(error))
        channel.runtime_state = {**channel.runtime_state, "poller_state": "failed"}

    def _mark_qr_request_error(self, channel: ChannelConfig, error_message: str) -> None:
        now = _now_epoch()
        channel.connection_state = "failed"
        channel.lifecycle_state = "failed"
        channel.last_error = _redact_error_message(error_message)
        channel.runtime_state = {
            **channel.runtime_state,
            "qr_login_state": "failed",
            "qr_login_requested_at": now,
            "qr_login_failed_at": now,
        }

    def _qr_state_from_response(self, response: dict[str, Any]) -> dict[str, Any]:
        qrcode = _find_first(
            response,
            "qrcode",
            "qr_code",
            "qrCode",
            "qr",
            "qr_string",
            "qrString",
            "qr_ticket",
            "qrTicket",
            "ticket",
        )
        qr_url = _find_first(
            response,
            "qr_login_url",
            "qrcode_url",
            "qrcodeUrl",
            "qrCodeUrl",
            "QRCodeUrl",
            "qr_url",
            "qrUrl",
            "qr_link",
            "qrLink",
            "login_url",
            "loginUrl",
            "url",
            "link",
        )
        expires_in = _find_first(response, "expires_in", "expire_seconds", "expires")
        state = {"qr_login_state": "ready"}
        if qrcode:
            state["qr_login_ticket"] = str(qrcode)
            state["qrcode"] = str(qrcode)
        if qr_url:
            state["qr_login_url"] = str(qr_url)
        if expires_in:
            state["qr_login_expires_at"] = int(time.time()) + int(expires_in)
        return state

    def _apply_login_payload(self, channel: ChannelConfig, payload: dict[str, Any]) -> None:
        token = _find_first(payload, "ilink_token", "token", "bot_token", "access_token")
        provider_account_id = _find_first(payload, "provider_account_id", "account_id", "wxid", "user_id", "bot_user_id")
        display_name = _find_first(payload, "display_name", "nickname", "nick_name", "name")
        if token:
            channel.ilink_token = str(token)
        if provider_account_id:
            channel.provider_account_id = str(provider_account_id)
        if display_name:
            channel.display_name = str(display_name)

    def _seen_message(self, channel: ChannelConfig, message_id: str) -> bool:
        ids = channel.runtime_state.get("message_dedup", {}).get("ids", [])
        return message_id in {str(item) for item in ids}

    def _remember_message(self, channel: ChannelConfig, message_id: str) -> None:
        dedup = dict(channel.runtime_state.get("message_dedup") or {})
        ids = [str(item) for item in dedup.get("ids", [])]
        ids.append(message_id)
        dedup["ids"] = ids[-1000:]
        dedup["updated_at"] = _now_epoch()
        channel.runtime_state = {**channel.runtime_state, "message_dedup": dedup}


def _find_first(payload: Any, *keys: str) -> Any:
    if isinstance(payload, dict):
        for key in keys:
            if key in payload and payload[key] not in (None, ""):
                return payload[key]
        for value in payload.values():
            found = _find_first(value, *keys)
            if found not in (None, ""):
                return found
    elif isinstance(payload, list):
        for item in payload:
            found = _find_first(item, *keys)
            if found not in (None, ""):
                return found
    return None


def _has_renderable_qr_payload(qr_state: dict[str, Any]) -> bool:
    return bool(qr_state.get("qr_login_url") or qr_state.get("qr_login_ticket") or qr_state.get("qrcode"))


def _log_qr_response_shape(channel_id: int, response: dict[str, Any]) -> None:
    shape = _payload_shape(response)
    LOGGER.warning(
        "Weixin iLink QR response missing renderable payload channel_id=%s response_shape=%s",
        channel_id,
        json.dumps(shape, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
    )


def _payload_shape(payload: Any, depth: int = 0) -> Any:
    if depth >= QR_RESPONSE_SHAPE_MAX_DEPTH:
        return type(payload).__name__
    if isinstance(payload, dict):
        return {
            str(key): _payload_shape(value, depth + 1)
            for key, value in sorted(payload.items(), key=lambda item: str(item[0]))
        }
    if isinstance(payload, list):
        if not payload:
            return []
        first = _payload_shape(payload[0], depth + 1)
        if len(payload) == 1:
            return [first]
        return [first, f"+{len(payload) - 1} more"]
    return type(payload).__name__


def _extract_messages(payload: dict[str, Any]) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    for key in ("message_list", "msg_list", "messages", "updates"):
        value = payload.get(key)
        if isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    message = item.get("msg") or item.get("message") or item
                    if isinstance(message, dict):
                        messages.append(message)
    data = payload.get("data")
    if isinstance(data, dict):
        messages.extend(_extract_messages(data))
    return messages


def _now_epoch() -> int:
    return int(time.time())


def _redact_error_message(message: str) -> str:
    return SENSITIVE_ERROR_PATTERN.sub(r"\1\2[REDACTED]", str(message))
