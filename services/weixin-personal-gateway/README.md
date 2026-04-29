# OneLink Weixin Personal Gateway

Native gateway boundary for a Weixin / WeChat Personal inbox backed by Tencent iLink Bot API.

Scope:
- internal service only, not a public webhook endpoint;
- accepts channel sync/runtime commands from Rails;
- long-polls iLink in the runtime worker layer;
- sends normalized events back to Rails `POST /webhooks/weixin/:webhook_identifier`;
- signs Rails callbacks with HS256 JWT using the per-channel webhook secret;
- keeps protocol code isolated from existing Chatwoot channels.

This skeleton intentionally has no dependency on external agent runtimes. iLink protocol details are implemented directly in `weixin_gateway/ilink.py`.

Local protocol tests:

```bash
cd services/weixin-personal-gateway
python3 -m unittest discover -s tests
```

Runtime wiring into docker/systemd is intentionally not added in this change; production rollout should happen separately after protocol tests and Rails specs are green.
