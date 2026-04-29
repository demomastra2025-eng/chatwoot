import base64
import json
import unittest

from weixin_gateway.callbacks import build_callback, normalize_message
from weixin_gateway.models import ChannelConfig
from weixin_gateway.security import jwt_hs256


def _decode_payload(token):
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))


class CallbackSecurityTest(unittest.TestCase):
    def test_jwt_hs256_contains_gateway_issuer_and_channel_id(self):
        token = jwt_hs256(
            {
                "iss": "onelink-weixin-personal-gateway",
                "channel_id": 42,
                "body_sha256": "a" * 64,
                "jti": "nonce-1",
                "exp": 4102444800,
            },
            "secret",
        )

        self.assertEqual(len(token.split(".")), 3)
        payload = _decode_payload(token)
        self.assertEqual(payload["iss"], "onelink-weixin-personal-gateway")
        self.assertEqual(payload["channel_id"], 42)
        self.assertEqual(payload["body_sha256"], "a" * 64)
        self.assertEqual(payload["jti"], "nonce-1")
        self.assertEqual(payload["exp"], 4102444800)
        self.assertIn("iat", payload)

    def test_callback_request_is_signed_for_rails_webhook(self):
        channel = ChannelConfig(
            id=42,
            ilink_token="token-1",
            callback_url="https://app.example.com/webhooks/weixin/abc",
            webhook_secret="secret",
        )

        callback = build_callback(channel, event="message.created", data={"message_id": "msg-1"})

        self.assertEqual(callback.url, "https://app.example.com/webhooks/weixin/abc")
        self.assertTrue(callback.headers["Authorization"].startswith("Bearer "))
        self.assertEqual(callback.headers["Content-Type"], "application/json")
        self.assertEqual(callback.json_body(), {"event": "message.created", "data": {"message_id": "msg-1"}})

        payload = _decode_payload(callback.headers["Authorization"].removeprefix("Bearer "))
        self.assertEqual(payload["iss"], "onelink-weixin-personal-gateway")
        self.assertEqual(payload["channel_id"], 42)
        self.assertEqual(len(payload["body_sha256"]), 64)
        self.assertTrue(payload["jti"])
        self.assertTrue(payload["exp"] > payload["iat"])

    def test_normalize_message_maps_ilink_user_fields(self):
        normalized = normalize_message(
            {
                "id": "msg-1",
                "from_user_id": "wxid_contact",
                "room_id": "room-1",
                "nickname": "Alice",
                "content": {"text": "hello"},
                "context_token": "context-token",
            }
        )

        self.assertEqual(normalized["message_id"], "msg-1")
        self.assertEqual(normalized["sender_id"], "wxid_contact")
        self.assertEqual(normalized["chat_id"], "room-1")
        self.assertEqual(normalized["sender_name"], "Alice")
        self.assertEqual(normalized["text"], "hello")
        self.assertEqual(normalized["context_token"], "context-token")


if __name__ == "__main__":
    unittest.main()
