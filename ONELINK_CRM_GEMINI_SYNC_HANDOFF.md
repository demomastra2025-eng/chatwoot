# Onelink CRM Gemini Sync Handoff

This is the operational handoff for synchronizing the Fonoster side with the
Onelink CRM and Gemini team.

Use this file when both sides are ready to connect production calls to the
Onelink-hosted `onelink-ai-voice` service.

This is an operational handoff, not the canonical schema contract. The canonical
contract remains `ONELINK_FONOSTER_VOICE_CONTRACT.md`.

## Production Boundary

```text
Fonoster
  Executes telecom: PSTN/SIP, numbers, trunks, app refs, voice.stream,
  dial/transfer, hangup, routing to selected OneLink runtime, and technical
  events. Fonoster does not own OneLink recording storage.

OneLink voice runtimes
  Run next to Onelink Rails. Own media path for recordable calls, recording
  writer/upload, recording lifecycle, and role-specific media logic:
  `onelink-ai-voice`, `onelink-operator-voice`, `onelink-app-voice`.
  These roles may initially be one shared runtime/codebase with different modes
  and app refs.

Onelink Rails / Chatwoot
  Owns CRM truth: context, prompts, tools, routing/fallback policy, contact and
  conversation state, transcript storage, recording metadata, permissions,
  signed playback/download URLs, retention, audit, UI, final call status, and
  business decisions.
```

Rails must not receive realtime audio frames. Rails receives JSON only.

## Fonoster-Side Work Completed

The local deployment bundle now contains the required Fonoster/onelink-ai-voice
side changes.

Implemented:

- bidirectional Fonoster stream support is expected from the patched local
  Fonoster source
- Fonoster-side reference/runtime bundle can keep `test-voiceapp/index.js` for
  staging, but production traffic must target the Onelink-hosted
  `onelink-ai-voice` endpoint
- Gemini Live realtime path with native audio
- 16 kHz caller input, 24 kHz Gemini output, resampling to call rate
- production latency defaults: provider greeting, no startup beeps, short output
  buffer, VAD/interruption config, short output tokens
- Rails context fetch before starting the realtime conversation
- canonical Gemini/Rails transfer tool `transfer_to_operator`
- Rails tool call `/internal/voice/ai/tools/transfer_to_operator`
- Rails tool call `/internal/voice/ai/tools/end_call`
- lifecycle/media/transcript/error events to `/internal/voice/ai/event`
- canonical `/internal/voice/ai/finalize`
- stable `event_id`, `event_seq`, `provider_call_id`, `ai_session_id`
- idempotency headers
- explicit `transfer_requested` and `transfer_result`
- unauthenticated private `/healthz` and `/readyz`
- script to create/update the Fonoster `EXTERNAL` app ref for the Onelink
  hosted endpoint

Important Fonoster-side files referenced by their team:

```text
test-voiceapp/index.js
voice-runtime/src/bridgeClient.js
telephony-bridge/scripts/sync-onelink-ai-voice-application.js
ONELINK_AI_VOICE_PRODUCTION.env.example
```

Important Onelink-side files:

```text
services/onelink-ai-voice/
ONELINK_EXTERNAL_GEMINI_LIVE_VOICEAPP.md
ONELINK_FONOSTER_VOICE_CONTRACT.md
ONELINK_BRIDGE_API_CONTRACT.md
```

## Onelink Must Provide

Onelink CRM/Gemini team must provide these deployment values:

```text
onelink_ai_voice_private_host=<private host or IP reachable from Fonoster>
onelink_ai_voice_grpc_endpoint=<private host>:50061
onelink_ai_voice_health_endpoint=http://<private host>:8081/readyz
onelink_internal_base_url=http://rails:3000 or private Rails URL
onelink_internal_secret=<shared secret between onelink-ai-voice and Rails>
gemini_api_key=<stored only on Onelink server>
operator_agent_aor=<production SIP AOR for transfer/fallback>
fallback_policy=<operator|finalize|fallback_app_ref per account>
```

Fonoster team does not need:

- Gemini API key
- Rails auth secret
- CRM database access
- prompt templates
- customer context rules
- CRM tool implementation
- operator selection rules beyond executable AORs returned by Rails

## Required Rails Endpoints

Onelink Rails must expose:

```text
POST /internal/voice/ai/context
POST /internal/voice/ai/tools/transfer_to_operator
POST /internal/voice/ai/tools/end_call
POST /internal/voice/ai/event
POST /internal/voice/ai/finalize
```

Compatibility endpoints that may remain:

```text
POST /internal/voice/ai/transcript
POST /internal/voice/ai/control
```

The current voice service defaults to sending transcript updates through
`/event` as `transcript_delta`. It can be switched to `/transcript` or both with:

```env
VOICE_AGENT_ONELINK_AI_TRANSCRIPT_MODE=event
```

Allowed values:

```text
event
transcript
both
```

## Auth And Idempotency

`onelink-ai-voice` sends the Rails AI auth token with:

```http
Content-Type: application/json
Authorization: Bearer <ONELINK_INTERNAL_SECRET>
X-Event-Id: <event_id>
X-Idempotency-Key: <event_id>
X-Event-Attempt: <attempt>
X-Request-Id: <uuid>
```

`X-Bridge-Secret` is for Fonoster bridge callbacks, not the canonical AI runtime
to Rails contract. If a transition deployment sends both headers, Rails will use
`Authorization: Bearer` for AI endpoints.

Rails must deduplicate by:

```text
event_id
```

or compatible:

```text
(provider_call_id, event_id)
(ai_session_id, event_seq)
```

`finalize` must be idempotent and return `2xx` on duplicate terminal payloads.

## Gemini Tool Mapping

Gemini sees tool names returned by Rails in `/internal/voice/ai/context`.

Canonical transfer tool name for this integration:

```text
transfer_to_operator
```

`onelink-ai-voice` calls Rails with the same tool name:

```text
POST /internal/voice/ai/tools/transfer_to_operator
```

Do not introduce a separate Gemini-facing alias for production. The production
contract uses `transfer_to_operator` end to end. Staging runtimes may accept
legacy aliases for compatibility, but aliases are not part of the Onelink
handoff contract.

Rails returns the executable low-level action:

```json
{
  "ok": true,
  "action": "transfer",
  "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz",
  "reason": "caller_requested_operator",
  "timeout": 30
}
```

Then `onelink-ai-voice` executes `voice.dial(...)` and emits:

```text
transfer_requested
transfer_result
finalize
```

Allowed transfer results:

```text
answered
no_answer
busy
failed
cancelled
```

## Onelink AI Voice Service Env

On the Onelink server:

```env
VOICE_AGENT_GRPC_PORT=50061
VOICE_AGENT_API_PORT=8081
VOICE_AGENT_VOICE_MODE=realtime
VOICE_AGENT_REALTIME_PROVIDER=gemini-live
VOICE_AGENT_REALTIME_MODEL=gemini-3.1-flash-live-preview
VOICE_AGENT_REALTIME_INPUT_RATE=16000
VOICE_AGENT_REALTIME_OUTPUT_RATE=24000
VOICE_AGENT_REALTIME_CALL_RATE=8000
VOICE_AGENT_REALTIME_GREETING_MODE=provider
VOICE_AGENT_REALTIME_STARTUP_BEEPS=false
VOICE_AGENT_REALTIME_OUTPUT_MAX_BUFFERED_MS=1500
VOICE_AGENT_REALTIME_MAX_OUTPUT_TOKENS=120
VOICE_AGENT_REALTIME_VAD_PREFIX_PADDING_MS=120
VOICE_AGENT_REALTIME_VAD_SILENCE_DURATION_MS=300
VOICE_AGENT_REALTIME_VAD_START_SENSITIVITY=START_SENSITIVITY_HIGH
VOICE_AGENT_REALTIME_VAD_END_SENSITIVITY=END_SENSITIVITY_HIGH
VOICE_AGENT_REALTIME_TURN_COVERAGE=TURN_INCLUDES_ONLY_ACTIVITY

VOICE_AGENT_ONELINK_AI_BASE_URL=http://rails:3000
VOICE_AGENT_ONELINK_AI_SHARED_SECRET=${ONELINK_INTERNAL_SECRET}
VOICE_AGENT_ONELINK_AI_CONTEXT_PATH=/internal/voice/ai/context
VOICE_AGENT_ONELINK_AI_TRANSCRIPT_PATH=/internal/voice/ai/transcript
VOICE_AGENT_ONELINK_AI_EVENT_PATH=/internal/voice/ai/event
VOICE_AGENT_ONELINK_AI_FINALIZE_PATH=/internal/voice/ai/finalize
GEMINI_API_KEY=<only on Onelink server>
```

Before production, Onelink must verify the selected Gemini Live model is enabled
for the Google project used by `GEMINI_API_KEY`.

## Fonoster-Side Switch

From the Fonoster deployment bundle, create or update the Fonoster `EXTERNAL`
application pointing to the Onelink-hosted voice service:

```bash
ONELINK_AI_VOICE_APP_ENDPOINT=<private-onelink-host>:50061 \
ONELINK_AI_VOICE_APP_NAME="Onelink Gemini Live Voice Agent" \
npm --prefix telephony-bridge run sync:onelink-ai-voice
```

The script refuses `test-voiceapp` and `localhost` endpoints unless explicitly
overridden with:

```env
ONELINK_AI_VOICE_ALLOW_LOCAL_ENDPOINT=true
```

After the script prints the app ref, set the Fonoster-side routing env:

```env
TELEPHONY_BRIDGE_DEFAULT_INBOUND_ACTION=ai
TELEPHONY_BRIDGE_DEFAULT_AI_MODE=onelink_managed
TELEPHONY_BRIDGE_ONELINK_AI_APP_REF=<printed ref>
TELEPHONY_BRIDGE_DEFAULT_AI_APP_REF=<printed ref>
```

Remove Gemini keys from the Fonoster server:

```env
VOICE_AGENT_REALTIME_API_KEY=
GEMINI_API_KEY=
GOOGLE_API_KEY=
```

The Fonoster server must not use `test-voiceapp:50061` as production target.

## Network Checks

From the Fonoster server:

```bash
nc -vz <private-onelink-host> 50061
curl -fsS http://<private-onelink-host>:8081/readyz
```

Expected `/readyz` shape:

```json
{
  "status": "ok",
  "ready": true,
  "realtimeProvider": "gemini-live",
  "realtimeConfigured": true,
  "onelinkAiConfigured": true
}
```

If gRPC is not TLS-protected, `50061` must be reachable only over private
network, VPN, or firewall allowlist.

## End-To-End Smoke Test

Run these tests before production traffic:

1. Inbound call to an AI-enabled number.
2. Verify `AUDIO_IN` reaches `onelink-ai-voice`.
3. Verify Gemini websocket opens.
4. Verify Gemini audio returns to the caller through `AUDIO_OUT`.
5. Interrupt Gemini while it speaks and verify playback buffer clears.
6. Verify Rails receives `call_started`, `stream_started`, `transcript_delta`.
7. Ask for operator and verify:
   - Gemini calls `transfer_to_operator`
   - Rails receives `/tools/transfer_to_operator`
   - `onelink-ai-voice` executes `voice.dial`
   - Rails receives `transfer_requested`
   - Rails receives `transfer_result`
8. Hang up and verify Rails receives exactly one terminal `finalize`.
9. Repeat the same final event and verify Rails returns duplicate-safe `2xx`.
10. Test operator no-answer and verify final status `operator_unavailable`.
11. Test Gemini key/model failure and verify configured fallback.
12. Test Rails context timeout and verify no audio callback blocks on Rails.

## Definition Of Done

The integration is ready when:

- Fonoster app ref points to `<private-onelink-host>:50061`
- `test-voiceapp:50061` is not a production target
- Gemini keys exist only on the Onelink server
- Rails stores/deduplicates events by `event_id`
- Rails finalizes idempotently
- transfer success and no-answer paths are represented in CRM
- inbound and outbound smoke calls pass with audio both ways
- no raw audio reaches Rails

## Message To Onelink Team

```text
We are ready to sync Fonoster with Onelink-hosted Gemini Live.

Fonoster will only execute calls and connect them to:
<private-onelink-host>:50061

Onelink owns CRM context, prompts, tools, transcript storage, fallback policy,
transfer decisions, and final call status.

Please confirm:
1. onelink-ai-voice private host/IP and health URL
2. Rails internal base URL from onelink-ai-voice
3. shared internal auth secret value for `Authorization: Bearer`
4. /internal/voice/ai/context response shape
5. /internal/voice/ai/tools/transfer_to_operator response shape
6. /internal/voice/ai/event idempotency behavior
7. /internal/voice/ai/finalize idempotency behavior
8. production operator_agent_aor and fallback policy
9. Gemini model/key availability for gemini-3.1-flash-live-preview

After that we will sync the Fonoster EXTERNAL app ref to the private endpoint
and run inbound/outbound smoke calls.
```