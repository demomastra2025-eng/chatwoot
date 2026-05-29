import unittest

from weixin_gateway.callbacks import normalize_message
from weixin_gateway.ilink import IlinkApiError
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
                    "qrcode_img_content": "https://ilink.example/qr/qr-ticket-1",
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

    def test_qr_status_redirect_scan_and_confirm_persist_credentials_and_start_poll_base_url(self):
        callbacks = []
        transport = FakeTransport(
            [
                {"status": "scaned"},
                {"status": "scaned_but_redirect", "redirect_host": "redirect.ilinkai.weixin.qq.com"},
                {
                    "status": "confirmed",
                    "ilink_bot_id": "bot-account-1",
                    "ilink_user_id": "user-1",
                    "bot_token": "bot-token-1",
                    "baseurl": "http://127.0.0.1:8097",
                },
                {"get_updates_buf": "cursor-after-login", "message_list": []},
            ]
        )
        registry = ChannelRegistry(transport=transport, callback_sender=callbacks.append, auto_start=False)
        registry.sync(
            42,
            {
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
            },
        )

        scanned = registry.poll_qr_status_once(42, "qr-ticket-1")
        redirected = registry.poll_qr_status_once(42, "qr-ticket-1", current_base_url=scanned["base_url"])
        confirmed = registry.poll_qr_status_once(42, "qr-ticket-1", current_base_url=redirected["base_url"])
        poll_result = registry.poll_once(42)

        self.assertFalse(scanned["terminal"])
        self.assertFalse(redirected["terminal"])
        self.assertTrue(confirmed["terminal"])
        self.assertEqual(redirected["base_url"], "https://redirect.ilinkai.weixin.qq.com")
        self.assertEqual(confirmed["channel"]["lifecycle_state"], "connected")
        self.assertEqual(confirmed["channel"]["provider_account_id"], "bot-account-1")
        self.assertEqual(confirmed["channel"]["runtime_state"]["base_url"], "https://redirect.ilinkai.weixin.qq.com")
        self.assertEqual(confirmed["channel"]["runtime_state"]["ilink_user_id"], "user-1")
        self.assertEqual(poll_result["channel"]["runtime_state"]["last_update_id"], "cursor-after-login")
        self.assertIn("https://redirect.ilinkai.weixin.qq.com/ilink/bot/getupdates", transport.requests[-1].url)
        self.assertEqual(callbacks[-1].json_body()["event"], "runtime.updated")
        self.assertEqual(callbacks[-1].json_body()["data"]["ilink_token"], "bot-token-1")
        self.assertEqual(callbacks[-1].json_body()["data"]["provider_account_id"], "bot-account-1")

    def test_qr_status_scan_ignores_incidental_unsafe_baseurl_until_redirect_or_confirm(self):
        callbacks = []
        transport = FakeTransport(
            [
                {
                    "status": "scaned",
                    "baseurl": "http://127.0.0.1:8097",
                    "ilink_bot_id": "incidental-bot-id",
                    "ilink_user_id": "incidental-user-id",
                }
            ]
        )
        registry = ChannelRegistry(transport=transport, callback_sender=callbacks.append, auto_start=False)
        registry.sync(
            42,
            {
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
            },
        )

        result = registry.poll_qr_status_once(42, "qr-ticket-1")

        self.assertFalse(result["terminal"])
        self.assertEqual(result["channel"]["connection_state"], "connecting")
        self.assertEqual(result["channel"]["lifecycle_state"], "qr_scanned")
        self.assertEqual(result["channel"]["runtime_state"]["qr_login_state"], "scaned")
        self.assertIsNone(result["channel"].get("last_error"))
        self.assertNotIn("base_url", result["channel"]["runtime_state"])
        self.assertIsNone(result["channel"].get("provider_account_id"))

    def test_rejects_unsafe_ilink_base_urls_before_polling_or_sending(self):
        registry = ChannelRegistry(transport=FakeTransport([]), auto_start=False)
        registry.sync(
            42,
            {
                "ilink_token": "token-1",
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
                "runtime_state": {"base_url": "http://127.0.0.1:8097"},
            },
        )

        with self.assertRaisesRegex(ValueError, "unsafe iLink base_url"):
            registry.poll_once(42)
        with self.assertRaisesRegex(ValueError, "unsafe iLink base_url"):
            registry.send_message(42, {"recipient_id": "wxid_contact", "text": "hello"})

    def test_accepts_ilink_wechat_redirect_host_from_qr_status(self):
        callbacks = []
        transport = FakeTransport([{"status": "scaned_but_redirect", "baseurl": "https://ilinkai.wechat.com"}])
        registry = ChannelRegistry(transport=transport, callback_sender=callbacks.append, auto_start=False)
        registry.sync(
            42,
            {
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
            },
        )

        result = registry.poll_qr_status_once(42, "qr-ticket-1")

        self.assertFalse(result["terminal"])
        self.assertEqual(result["base_url"], "https://ilinkai.wechat.com")
        self.assertEqual(result["channel"]["lifecycle_state"], "qr_scanned")
        self.assertEqual(result["channel"]["runtime_state"]["qr_login_state"], "scaned_but_redirect")
        self.assertEqual(result["channel"]["runtime_state"]["qr_status_base_url"], "https://ilinkai.wechat.com")
        self.assertIsNone(result["channel"].get("last_error"))

    def test_ignores_unsafe_redirect_hosts_from_qr_status(self):
        callbacks = []
        transport = FakeTransport([{"status": "scaned_but_redirect", "redirect_host": "127.0.0.1:8097"}])
        registry = ChannelRegistry(transport=transport, callback_sender=callbacks.append, auto_start=False)
        registry.sync(
            42,
            {
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
            },
        )

        result = registry.poll_qr_status_once(42, "qr-ticket-1")

        self.assertFalse(result["terminal"])
        self.assertEqual(result["base_url"], "https://ilinkai.weixin.qq.com")
        self.assertEqual(result["channel"]["lifecycle_state"], "qr_scanned")
        self.assertEqual(result["channel"]["runtime_state"]["qr_login_state"], "scaned_but_redirect")
        self.assertNotIn("base_url", result["channel"]["runtime_state"])
        self.assertNotIn("qr_status_base_url", result["channel"]["runtime_state"])
        self.assertIsNone(result["channel"].get("last_error"))

    def test_qr_confirmed_without_credentials_fails_safely(self):
        callbacks = []
        transport = FakeTransport([{"status": "confirmed", "ilink_bot_id": "bot-account-1"}])
        registry = ChannelRegistry(transport=transport, callback_sender=callbacks.append, auto_start=False)
        registry.sync(
            42,
            {
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
            },
        )

        result = registry.poll_qr_status_once(42, "qr-ticket-1")

        self.assertTrue(result["terminal"])
        self.assertEqual(result["channel"]["connection_state"], "failed")
        self.assertEqual(result["channel"]["lifecycle_state"], "failed")
        self.assertEqual(result["channel"]["runtime_state"]["qr_login_state"], "failed")
        self.assertIn("credential payload was incomplete", result["channel"]["last_error"])
        self.assertNotIn("secret", str(result["channel"]).lower())
        self.assertEqual(callbacks[-1].json_body()["event"], "runtime.updated")

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
                "runtime_state": {"base_url": "https://redirect.ilinkai.weixin.qq.com"},
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
        self.assertIn("https://redirect.ilinkai.weixin.qq.com/ilink/bot/sendmessage", request.url)
        body = request.json_body()
        self.assertEqual(body["msg"]["to_user_id"], "wxid_contact")
        self.assertEqual(body["msg"]["context_token"], "message-context")
        self.assertEqual(body["msg"]["item_list"][0]["text_item"]["text"], "hello **markdown**")

    def test_poll_once_treats_ilink_524_as_empty_long_poll_and_recovers_state(self):
        callbacks = []
        transport = FakeTransport([IlinkApiError("iLink HTTP 524: ")])
        registry = ChannelRegistry(transport=transport, callback_sender=callbacks.append, auto_start=False)
        registry.sync(
            42,
            {
                "ilink_token": "token-1",
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
                "connection_state": "failed",
                "lifecycle_state": "failed",
                "runtime_state": {"poller_state": "failed", "get_updates_buf": "cursor-1"},
            },
        )

        result = registry.poll_once(42)

        self.assertEqual(result["processed"], 0)
        self.assertEqual(result["channel"]["connection_state"], "connected")
        self.assertEqual(result["channel"]["lifecycle_state"], "connected")
        self.assertIsNone(result["channel"].get("last_error"))
        self.assertEqual(result["channel"]["runtime_state"]["poller_state"], "running")
        self.assertEqual(result["channel"]["runtime_state"]["get_updates_buf"], "cursor-1")
        self.assertEqual(callbacks[-1].json_body()["event"], "runtime.updated")

    def test_poll_once_reads_hermes_msgs_response_shape(self):
        callbacks = []
        transport = FakeTransport(
            [
                {
                    "get_updates_buf": "cursor-2",
                    "msgs": [
                        {
                            "message_id": "msg-1",
                            "from_user_id": "wxid_contact",
                            "item_list": [{"type": 1, "text_item": {"text": "hello from msgs"}}],
                        }
                    ],
                }
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
        self.assertEqual(callbacks[0].json_body()["event"], "message.created")
        self.assertEqual(callbacks[0].json_body()["data"]["message_id"], "msg-1")
        self.assertEqual(callbacks[0].json_body()["data"]["text"], "hello from msgs")

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
