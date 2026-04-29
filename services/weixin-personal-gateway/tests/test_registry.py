import unittest

from weixin_gateway.registry import ChannelRegistry


class RegistryTest(unittest.TestCase):
    def test_sync_keeps_secrets_out_of_public_channel_state(self):
        registry = ChannelRegistry()
        result = registry.sync(
            42,
            {
                "ilink_token": "token-1",
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
                "provider_account_id": "wxid_bot",
                "display_name": "Bot",
                "context_token": "context-secret",
                "context_tokens": {"wxid_contact": "peer-context-secret"},
                "runtime_state": {"poller_state": "idle"},
            },
        )

        channel = result["channel"]
        self.assertEqual(channel["provider_account_id"], "wxid_bot")
        self.assertEqual(channel["runtime_state"], {"poller_state": "idle"})
        self.assertNotIn("ilink_token", channel)
        self.assertNotIn("webhook_secret", channel)
        self.assertNotIn("context_token", channel)
        self.assertNotIn("context_tokens", channel)
        self.assertEqual(registry.get(42).token_for_peer("wxid_contact"), "peer-context-secret")
        credential_state = registry.get(42).credential_update_state()
        self.assertEqual(credential_state["context_token"], "context-secret")
        self.assertEqual(credential_state["ilink_token"], "token-1")
        self.assertNotIn("context_tokens", credential_state)

    def test_diagnostics_reports_secret_presence_without_values(self):
        registry = ChannelRegistry()
        registry.sync(
            42,
            {
                "ilink_token": "token-1",
                "context_token": "context-secret",
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
            },
        )

        diagnostics = registry.diagnostics(42)

        self.assertTrue(diagnostics["synced"])
        self.assertEqual(diagnostics["secrets_present"], {"ilink_token": True, "webhook_secret": True})
        self.assertNotIn("token-1", str(diagnostics))
        self.assertNotIn("context-secret", str(diagnostics))
        self.assertNotIn("secret", str(diagnostics["channel"]))

    def test_public_runtime_errors_are_redacted(self):
        registry = ChannelRegistry()
        registry.sync(
            42,
            {
                "callback_url": "https://app.example.com/webhooks/weixin/abc",
                "webhook_secret": "secret",
            },
        )

        result = registry.apply_runtime_update(42, last_error="token: raw-secret-value failed")

        self.assertIn("[REDACTED]", result["channel"]["last_error"])
        self.assertNotIn("raw-secret-value", result["channel"]["last_error"])

    def test_unsynced_channel_raises_boundary_error(self):
        with self.assertRaisesRegex(KeyError, "Channel 42 is not synced"):
            ChannelRegistry().diagnostics(42)


if __name__ == "__main__":
    unittest.main()
