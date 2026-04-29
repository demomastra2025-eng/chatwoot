from __future__ import annotations

import base64
import json
import re
import secrets
import struct
from dataclasses import dataclass
from typing import Any
from urllib import error, request
from urllib.parse import quote

ILINK_BASE_URL = "https://ilinkai.weixin.qq.com"
ILINK_APP_ID = "bot"
CHANNEL_VERSION = "2.2.0"
ILINK_APP_CLIENT_VERSION = (2 << 16) | (2 << 8) | 0

EP_GET_UPDATES = "ilink/bot/getupdates"
EP_SEND_MESSAGE = "ilink/bot/sendmessage"
EP_GET_BOT_QR = "ilink/bot/get_bot_qrcode"
EP_GET_QR_STATUS = "ilink/bot/get_qrcode_status"

ITEM_TEXT = 1
MSG_TYPE_BOT = 2
MSG_STATE_FINISH = 2
LONG_POLL_TIMEOUT_MS = 35_000
API_TIMEOUT_MS = 15_000
QR_TIMEOUT_MS = 35_000
MAX_TEXT_MESSAGE_LENGTH = 4000


class IlinkApiError(RuntimeError):
    pass


SENSITIVE_ERROR_PATTERN = re.compile(
    r"(authorization|bearer|token|secret|password|api[_-]?key|connection[_-]?string)([\"'\s:=]+)([^\"'\s,}]+)",
    re.IGNORECASE,
)


def _json_dumps(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def _random_wechat_uin() -> str:
    value = struct.unpack(">I", secrets.token_bytes(4))[0]
    return base64.b64encode(str(value).encode("utf-8")).decode("ascii")


@dataclass(frozen=True)
class IlinkRequest:
    method: str
    url: str
    headers: dict[str, str]
    body: str = ""
    timeout_seconds: float = 15.0

    def json_body(self) -> dict[str, Any]:
        return json.loads(self.body) if self.body else {}


class IlinkClient:
    def __init__(self, base_url: str = ILINK_BASE_URL):
        self.base_url = base_url.rstrip("/")

    def get_updates_request(self, *, token: str, sync_buf: str = "", timeout_ms: int = LONG_POLL_TIMEOUT_MS) -> IlinkRequest:
        return self._post(
            EP_GET_UPDATES,
            {"get_updates_buf": sync_buf},
            token=token,
            timeout_ms=timeout_ms,
        )

    def send_text_message_request(
        self,
        *,
        token: str,
        to_user_id: str,
        text: str,
        context_token: str | None = None,
        client_id: str | None = None,
    ) -> IlinkRequest:
        if not text or not text.strip():
            raise ValueError("text must not be empty")
        if not to_user_id:
            raise ValueError("to_user_id must be present")

        message: dict[str, Any] = {
            "from_user_id": "",
            "to_user_id": to_user_id,
            "client_id": client_id or secrets.token_hex(16),
            "message_type": MSG_TYPE_BOT,
            "message_state": MSG_STATE_FINISH,
            "item_list": [{"type": ITEM_TEXT, "text_item": {"text": text}}],
        }
        if context_token:
            message["context_token"] = context_token

        return self._post(EP_SEND_MESSAGE, {"msg": message}, token=token, timeout_ms=API_TIMEOUT_MS)

    def get_bot_qr_request(self, *, bot_type: int = 2) -> IlinkRequest:
        return self._get(f"{EP_GET_BOT_QR}?bot_type={quote(str(bot_type), safe='')}", timeout_ms=QR_TIMEOUT_MS)

    def get_qr_status_request(self, *, qrcode: str, base_url: str | None = None) -> IlinkRequest:
        if not qrcode:
            raise ValueError("qrcode must be present")
        client = self if base_url is None else IlinkClient(base_url)
        return client._get(f"{EP_GET_QR_STATUS}?qrcode={quote(qrcode, safe='')}", timeout_ms=QR_TIMEOUT_MS)

    def _post(self, endpoint: str, payload: dict[str, Any], *, token: str, timeout_ms: int) -> IlinkRequest:
        body = _json_dumps({**payload, "base_info": {"channel_version": CHANNEL_VERSION}})
        return IlinkRequest(
            method="POST",
            url=f"{self.base_url}/{endpoint}",
            headers={
                "Content-Type": "application/json",
                "AuthorizationType": "ilink_bot_token",
                "Content-Length": str(len(body.encode("utf-8"))),
                "X-WECHAT-UIN": _random_wechat_uin(),
                "iLink-App-Id": ILINK_APP_ID,
                "iLink-App-ClientVersion": str(ILINK_APP_CLIENT_VERSION),
                "Authorization": f"Bearer {token}",
            },
            body=body,
            timeout_seconds=timeout_ms / 1000,
        )

    def _get(self, endpoint: str, *, timeout_ms: int) -> IlinkRequest:
        return IlinkRequest(
            method="GET",
            url=f"{self.base_url}/{endpoint}",
            headers={
                "iLink-App-Id": ILINK_APP_ID,
                "iLink-App-ClientVersion": str(ILINK_APP_CLIENT_VERSION),
            },
            timeout_seconds=timeout_ms / 1000,
        )


class HttpIlinkTransport:
    def execute(self, ilink_request: IlinkRequest) -> dict[str, Any]:
        data = ilink_request.body.encode("utf-8") if ilink_request.body else None
        req = request.Request(
            ilink_request.url,
            data=data,
            headers=ilink_request.headers,
            method=ilink_request.method,
        )
        try:
            with request.urlopen(req, timeout=ilink_request.timeout_seconds) as response:
                body = response.read().decode("utf-8")
                return json.loads(body) if body else {}
        except error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise IlinkApiError(f"iLink HTTP {exc.code}: {_redact_error(body)}") from exc
        except error.URLError as exc:
            raise IlinkApiError(f"iLink request failed: {exc.reason}") from exc
        except json.JSONDecodeError as exc:
            raise IlinkApiError("iLink response is not valid JSON") from exc


def _redact_error(message: str) -> str:
    return SENSITIVE_ERROR_PATTERN.sub(r"\1\2[REDACTED]", str(message))


def split_text_for_weixin(text: str, *, limit: int = MAX_TEXT_MESSAGE_LENGTH) -> list[str]:
    normalized = str(text or "").strip()
    if not normalized:
        raise ValueError("text must not be empty")
    if len(normalized) <= limit:
        return [normalized]

    chunks: list[str] = []
    current = ""
    for block in normalized.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        candidate = f"{current}\n\n{block}" if current else block
        if len(candidate) <= limit:
            current = candidate
            continue
        if current:
            chunks.append(current)
            current = ""
        while len(block) > limit:
            chunks.append(block[:limit])
            block = block[limit:]
        current = block
    if current:
        chunks.append(current)
    return chunks
