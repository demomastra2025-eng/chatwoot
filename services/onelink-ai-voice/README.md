# OneLink AI Voice Service

Realtime voice runtime for OneLink calls.

Ownership split:

- Janus/WhatsApp media gateway: call/media execution.
- `onelink-ai-voice`: realtime audio session, Gemini Live adapter, transcript/tool/control buffering.
- Rails/Chatwoot: routing, context, Captain config, tools, transcript persistence, lifecycle/audit.

Audio must stay out of Rails: `media gateway <-> onelink-ai-voice <-> Gemini Live`.
Rails is used only through authenticated internal control-plane APIs.

Runtime attach endpoints:

- `POST /internal/whatsapp-cloud/calls` for WhatsApp media-server runtime streams.
- `POST /internal/janus-sip/calls` for Janus SIP AI runtime streams.

The Janus endpoint is intentionally a separate path from browser/operator Janus sessions.

Janus SIP RTP forwarding is available only when explicitly requested by the attach payload:

```json
{
  "janus": {
    "unique_id": "janus-sip-plugin-unique-id",
    "session_id": "123",
    "handle_id": "456",
    "rtp_forward": {
      "enabled": true,
      "streams": [
        { "type": "peer_audio", "host": "janus-ai-gateway", "port": 40000 }
      ]
    }
  }
}
```

This maps to the Janus SIP plugin Admin API `rtp_forward` command. Use `peer_audio` for the SIP caller/provider side. The returned forwarder metadata is attached to `payload.janus.rtp_forward_result` before the current voice agent starts.

The service can also create an in-process RTP runtime bridge for Janus:

```json
{
  "janus": {
    "unique_id": "janus-sip-plugin-unique-id",
    "rtp_bridge": { "enabled": true },
    "rtp_forward": { "enabled": true }
  }
}
```

When `VOICE_AGENT_JANUS_RTP_BRIDGE_ENABLED=true`, this creates a runtime media stream inside `onelink-ai-voice`, allocates a unique RTP SSRC, fills `runtime_stream.kind=janus_rtp_bridge`, and auto-populates `rtp_forward.streams` when none are provided. Janus SIP `rtp_forward` is one-way; caller audio reaches the agent. For the caller to hear AI audio, provide a real reverse RTP target/media leg through `VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_HOST` and `VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_PORT` or a dedicated Janus/NoSIP bridge.

Required env:

- `ONELINK_INTERNAL_BASE_URL`
- `ONELINK_INTERNAL_TOKEN`
- `VOICE_AGENT_REALTIME_API_KEY` or `GEMINI_API_KEY`

Optional Janus Admin API env:

- `VOICE_AGENT_JANUS_ADMIN_URL`
- `VOICE_AGENT_JANUS_ALLOWED_PROVIDERS`
- `VOICE_AGENT_JANUS_ADMIN_SECRET`
- `VOICE_AGENT_JANUS_SIP_ADMIN_KEY`
- `VOICE_AGENT_JANUS_RTP_FORWARD_HOST`
- `VOICE_AGENT_JANUS_RTP_FORWARD_PEER_AUDIO_PORT`
- `VOICE_AGENT_JANUS_RTP_BRIDGE_ENABLED`
- `VOICE_AGENT_JANUS_RTP_BRIDGE_LISTEN_PORT`
- `VOICE_AGENT_JANUS_RTP_BRIDGE_PUBLIC_HOST`
- `VOICE_AGENT_JANUS_RTP_BRIDGE_INPUT_CODEC`
- `VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_HOST`
- `VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_PORT`

Browser bridge hardening env:

- `VOICE_AGENT_JANUS_BROWSER_BRIDGE_ALLOWED_ORIGINS` — comma-separated trusted HTTPS origins.
- `VOICE_AGENT_JANUS_BROWSER_BRIDGE_MAX_PAYLOAD_BYTES` — WebSocket message limit, default `131072`.
- `VOICE_AGENT_JANUS_BROWSER_BRIDGE_MAX_AUDIO_BYTES` — decoded audio frame limit, default `65536`.
- `VOICE_AGENT_JANUS_BROWSER_BRIDGE_MAX_SESSIONS` — process-wide session cap, default `256`.
- `VOICE_AGENT_JANUS_BROWSER_BRIDGE_ATTACH_TIMEOUT_MS` — unattached session TTL, default `60000`.
- `VOICE_AGENT_JANUS_BROWSER_BRIDGE_IDLE_TIMEOUT_MS` — disconnected session TTL, default `30000`.

Browser bridge URLs contain short-lived capability tokens. The reverse proxy
must disable access logging for this path so query tokens never enter log
storage.

Server-side Janus SIP voice-agent runtime is separate from the operator browser
webphone. It is disabled by default. When enabled, it reads managed voice-agent
SIP profiles from Chatwoot through the internal
`/internal/voice/ai/janus-sip/profiles` endpoint and keeps Janus registrations in
sync with inbox configuration changes. `VOICE_AGENT_JANUS_SERVER_PROFILES_JSON`
is only a local fallback for isolated tests.

When enabled, `onelink-ai-voice` connects to Janus WebSocket, registers only the
configured `voice_agent` SIP profiles, accepts incoming SIP calls by creating a
Pion WebRTC session in `chatwoot_media_server`, and then uses the existing
runtime stream path for Gemini Live audio. Both regular INVITEs with an SDP
offer and native offerless SIP INVITEs are negotiated; offerless calls use the
media server offer followed by the SDP answer received in the SIP ACK. Janus
WebSocket connection attempts are time-bounded so one unreachable gateway
cannot stall the profile synchronization loop.

Required server-side Janus env:

- `VOICE_AGENT_JANUS_SERVER_RUNTIME_ENABLED=true`
- `VOICE_AGENT_JANUS_SERVER_WS_URL=ws://janus_gateway:8188`
- `VOICE_AGENT_JANUS_SERVER_SIPUNI_WS_URL=ws://janus_gateway:8188`
- `VOICE_AGENT_JANUS_SERVER_BINOTEL_WS_URL=ws://janus_gateway:8188`
- `VOICE_AGENT_JANUS_SERVER_ASTERISK_ANALOG_WS_URL=ws://host.docker.internal:8189`
- `VOICE_AGENT_JANUS_MEDIA_SERVER_URL=http://chatwoot_media_server:4000`
- `VOICE_AGENT_JANUS_MEDIA_SERVER_TOKEN=<MEDIA_SERVER_AUTH_TOKEN>`
- `VOICE_AGENT_JANUS_SERVER_PROFILES_PATH=/internal/voice/ai/janus-sip/profiles`
- `VOICE_AGENT_JANUS_SERVER_PROFILE_SYNC_INTERVAL_MS=15000`
- `VOICE_AGENT_JANUS_SERVER_MAX_CALLS_PER_PROFILE=4`
- `VOICE_AGENT_JANUS_SERVER_REGISTRATION_CONCURRENCY=10`

Each profile uses one registered Janus SIP master handle and a bounded pool of
native helper handles. Routing-only configuration changes are applied to new
calls without dropping calls already in progress. SIP credential, transport,
or pool-size changes rebuild only the affected profile session.

Provider-specific Janus URLs are optional overrides. If a provider URL is blank,
the runtime falls back to `VOICE_AGENT_JANUS_SERVER_WS_URL`. This lets
Sipuni/Binotel use the default Janus gateway while Asterisk analog uses the
separate Asterisk Janus gateway.

Fallback profile JSON for isolated local tests:

```json
[
  {
    "id": 12,
    "account_id": 42,
    "inbox_id": 9,
    "number_ref": "sipuni-main",
    "provider": "sipuni",
    "phone_number": "+77001234567",
    "internal_extension": "9098",
    "sip_username": "ai-agent-9098",
    "sip_password": "secret",
    "sip_host": "sip.example.kz",
    "sip_transport": "udp"
  }
]
```

Scripts:

- `npm test`
- `npm start`
