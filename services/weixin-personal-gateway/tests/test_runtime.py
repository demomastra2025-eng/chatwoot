import unittest

from weixin_gateway.callbacks import normalize_message
from weixin_gateway.registry import ChannelRegistry


class FakeTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def execute(self, request):
        self.requests.append(request)
        if not self.responses:
            raise AssertionError("unexpected transport call")
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class RuntimeIntegrationTest(unittest.TestCase):
    def test_sync_allows_qr_first_channel_without_token(self):
        registry = ChannelRegistry(auto_start=False)

        result = registry.sync(
            42,
            {
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
                "display_name": "Pending QR",
            },
        )

        channel = result["channel"]
        self.assertEqual(channel["lifecycle_state"], "pending_auth")
        self.assertEqual(channel["connection_state"], "disconnected")
        self.assertNotIn("ilink_token", channel)
        self.assertNotIn("webhook_secret", channel)

    def test_request_qr_uses_ilink_qr_api_and_stores_safe_login_state(self):
        transport = FakeTransport(
            [
                {
                    "qrcode": "qr-ticket-1",
                    "qrcode_url": "https://ilink.example/qr/qr-ticket-1",
                    "expires_in": 120,
                }
            ]
        )
        registry = ChannelRegistry(transport=transport, auto_start=False)
        registry.sync(
            42,
            {
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
            },
        )

        result = registry.request_qr(42)

        self.assertEqual(transport.requests[0].method, "GET")
        self.assertIn("get_bot_qrcode", transport.requests[0].url)
        channel = result["channel"]
        self.assertEqual(channel["connection_state"], "connecting")
        self.assertEqual(channel["lifecycle_state"], "qr_ready")
        self.assertEqual(channel["runtime_state"]["qr_login_url"], "https://ilink.example/qr/qr-ticket-1")
        self.assertEqual(channel["runtime_state"]["qr_login_state"], "ready")
        self.assertNotIn("ilink_token", str(channel))

    def test_request_qr_fails_and_logs_safe_shape_when_ilink_response_has_no_renderable_qr(self):
        transport = FakeTransport(
            [
                {
                    "ok": True,
                    "data": {"status": "ready", "nested": {"value": "not-a-qr"}},
                    "token": "raw-secret-token",
                }
            ]
        )
        registry = ChannelRegistry(transport=transport, auto_start=False)
        registry.sync(
            42,
            {
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
            },
        )

        with self.assertLogs("weixin_gateway.registry", level="WARNING") as logs:
            with self.assertRaisesRegex(ValueError, "iLink QR response did not include a renderable QR payload"):
                registry.request_qr(42)

        channel = registry.diagnostics(42)["channel"]
        self.assertEqual(channel["connection_state"], "failed")
        self.assertEqual(channel["lifecycle_state"], "failed")
        self.assertEqual(channel["runtime_state"]["qr_login_state"], "failed")
        self.assertIn("data", logs.output[0])
        self.assertIn("nested", logs.output[0])
        self.assertNotIn("raw-secret-token", logs.output[0])
        self.assertNotIn("secret", str(channel))

    def test_send_message_posts_native_ilink_payload_with_context_token(self):
        transport = FakeTransport([{"message_id": "provider-msg-1"}])
        registry = ChannelRegistry(transport=transport, auto_start=False)
        registry.sync(
            42,
            {
                "ilink_token": "token-1",
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
                "context_token": "channel-context",
            },
        )

        result = registry.send_message(
            42,
            {
                "recipient_id": "wxid_contact",
                "text": "hello **markdown**",
                "context_token": "message-context",
                "client_id": "client-1",
            },
        )

        self.assertEqual(result["message_id"], "provider-msg-1")
        request = transport.requests[0]
        self.assertIn("sendmessage", request.url)
        body = request.json_body()
        self.assertEqual(body["msg"]["to_user_id"], "wxid_contact")
        self.assertEqual(body["msg"]["context_token"], "message-context")
        self.assertEqual(body["msg"]["item_list"][0]["text_item"]["text"], "hello **markdown**")

    def test_poll_once_normalizes_updates_posts_callback_and_deduplicates_message_ids(self):
        callbacks = []
        transport = FakeTransport(
            [
                {
                    "get_updates_buf": "cursor-2",
                    "message_list": [
                        {
                            "id": "msg-1",
                            "from_user_id": "wxid_contact",
                            "nickname": "Alice",
                            "item_list": [{"type": 1, "text_item": {"text": "hello"}}],
                            "context_token": "ctx-1",
                        },
                        {
                            "id": "msg-1",
                            "from_user_id": "wxid_contact",
                            "item_list": [{"type": 1, "text_item": {"text": "duplicate"}}],
                        },
                    ],
                },
                {"message_id": "reply-1"},
            ]
        )
        registry = ChannelRegistry(transport=transport, callback_sender=callbacks.append, auto_start=False)
        registry.sync(
            42,
            {
                "ilink_token": "token-1",
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
            },
        )

        result = registry.poll_once(42)

        self.assertEqual(result["processed"], 1)
        self.assertEqual(result["channel"]["runtime_state"]["last_update_id"], "cursor-2")
        self.assertEqual(len(callbacks), 1)
        self.assertEqual(callbacks[0].json_body()["event"], "message.created")
        self.assertEqual(callbacks[0].json_body()["data"]["message_id"], "msg-1")
        self.assertEqual(callbacks[0].json_body()["data"]["sender_id"], "wxid_contact")
        self.assertEqual(callbacks[0].json_body()["data"]["text"], "hello")
        self.assertEqual(registry.send_message(42, {"recipient_id": "wxid_contact", "text": "reply"})["context_token"], "ctx-1")


class NormalizeMessageTest(unittest.TestCase):
    def test_extracts_text_from_ilink_item_list(self):
        normalized = normalize_message(
            {
                "id": "msg-1",
                "from_user_id": "wxid_contact",
                "item_list": [{"type": 1, "text_item": {"text": "hello from item"}}],
            }
        )

        self.assertEqual(normalized["text"], "hello from item")


if __name__ == "__main__":
    unittest.main()
