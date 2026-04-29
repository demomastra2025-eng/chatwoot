from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

from .config import GatewayConfig
from .registry import ChannelRegistry
from .security import constant_time_equal

REGISTRY = ChannelRegistry(auto_start=True)


def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class GatewayHandler(BaseHTTPRequestHandler):
    config = GatewayConfig.from_env()

    def do_GET(self) -> None:
        if not self._authorized():
            _json_response(self, 401, {"error": "Unauthorized"})
            return
        try:
            channel_id, action = self._route()
            if action == "diagnostics":
                _json_response(self, 200, REGISTRY.diagnostics(channel_id))
                return
            _json_response(self, 404, {"error": "Not found"})
        except Exception as exc:
            _json_response(self, 422, {"error": str(exc)})

    def do_POST(self) -> None:
        if not self._authorized():
            _json_response(self, 401, {"error": "Unauthorized"})
            return
        try:
            channel_id, action = self._route()
            payload = self._json_body()
            if action == "sync":
                _json_response(self, 200, REGISTRY.sync(channel_id, payload))
            elif action == "request-qr":
                _json_response(self, 200, REGISTRY.request_qr(channel_id, payload.get("qr_login_url")))
            elif action == "reconnect":
                _json_response(self, 200, REGISTRY.reconnect(channel_id))
            elif action == "disconnect":
                _json_response(self, 200, REGISTRY.disconnect(channel_id))
            elif action == "messages":
                _json_response(self, 200, REGISTRY.send_message(channel_id, payload))
            else:
                _json_response(self, 404, {"error": "Not found"})
        except Exception as exc:
            _json_response(self, 422, {"error": str(exc)})

    def do_DELETE(self) -> None:
        if not self._authorized():
            _json_response(self, 401, {"error": "Unauthorized"})
            return
        try:
            channel_id, action = self._route()
            if action == "delete":
                _json_response(self, 200, REGISTRY.delete(channel_id))
            else:
                _json_response(self, 404, {"error": "Not found"})
        except Exception as exc:
            _json_response(self, 422, {"error": str(exc)})

    def _authorized(self) -> bool:
        expected = self.config.gateway_token
        if not expected:
            return False
        value = self.headers.get("Authorization", "")
        return value.startswith("Bearer ") and constant_time_equal(value.removeprefix("Bearer "), expected)

    def _json_body(self) -> dict:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def _route(self) -> tuple[int, str]:
        parts = [part for part in urlparse(self.path).path.split("/") if part]
        # /internal/channels/:id/(sync|reconnect|disconnect|messages|diagnostics)
        # /internal/channels/:id/auth/request-qr
        if len(parts) < 3 or parts[0:2] != ["internal", "channels"]:
            raise ValueError("Invalid gateway path")
        channel_id = int(parts[2])
        if len(parts) == 3:
            return channel_id, "delete"
        if parts[3:5] == ["auth", "request-qr"]:
            return channel_id, "request-qr"
        return channel_id, parts[3]


def run() -> None:
    config = GatewayConfig.from_env()
    GatewayHandler.config = config
    HTTPServer((config.host, config.port), GatewayHandler).serve_forever()


if __name__ == "__main__":
    run()
