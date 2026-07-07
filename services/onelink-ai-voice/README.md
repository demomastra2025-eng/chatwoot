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

Scripts:

- `npm test`
- `npm start`
