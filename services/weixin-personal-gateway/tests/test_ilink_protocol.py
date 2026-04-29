import unittest

from weixin_gateway.ilink import (
    CHANNEL_VERSION,
    EP_GET_UPDATES,
    EP_SEND_MESSAGE,
    ILINK_APP_CLIENT_VERSION,
    ILINK_BASE_URL,
    IlinkClient,
)


class IlinkProtocolTest(unittest.TestCase):
    def test_get_updates_request_uses_ilink_headers_and_sync_buffer(self):
        request = IlinkClient().get_updates_request(token="token-1", sync_buf="cursor-1")

        self.assertEqual(request.method, "POST")
        self.assertEqual(request.url, f"{ILINK_BASE_URL}/{EP_GET_UPDATES}")
        self.assertEqual(request.headers["Authorization"], "Bearer token-1")
        self.assertEqual(request.headers["AuthorizationType"], "ilink_bot_token")
        self.assertEqual(request.headers["iLink-App-Id"], "bot")
        self.assertEqual(request.headers["iLink-App-ClientVersion"], str(ILINK_APP_CLIENT_VERSION))
        self.assertIn("X-WECHAT-UIN", request.headers)
        self.assertEqual(request.json_body()["get_updates_buf"], "cursor-1")
        self.assertEqual(request.json_body()["base_info"], {"channel_version": CHANNEL_VERSION})

    def test_send_text_message_request_builds_native_message_payload(self):
        request = IlinkClient().send_text_message_request(
            token="token-1",
            to_user_id="wxid_contact",
            text="hello",
            context_token="context-token",
            client_id="client-1",
        )

        self.assertEqual(request.url, f"{ILINK_BASE_URL}/{EP_SEND_MESSAGE}")
        body = request.json_body()
        self.assertEqual(body["msg"]["to_user_id"], "wxid_contact")
        self.assertEqual(body["msg"]["client_id"], "client-1")
        self.assertEqual(body["msg"]["context_token"], "context-token")
        self.assertEqual(body["msg"]["message_type"], 2)
        self.assertEqual(body["msg"]["message_state"], 2)
        self.assertEqual(body["msg"]["item_list"], [{"type": 1, "text_item": {"text": "hello"}}])

    def test_send_text_message_rejects_empty_text(self):
        with self.assertRaisesRegex(ValueError, "text must not be empty"):
            IlinkClient().send_text_message_request(token="token-1", to_user_id="wxid_contact", text=" ")


if __name__ == "__main__":
    unittest.main()
