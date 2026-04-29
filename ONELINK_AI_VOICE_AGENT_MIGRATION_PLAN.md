# Onelink AI Voice Agent Migration Plan

This document describes how to move the current Gemini AI voice-agent ownership
to Onelink while keeping realtime audio fast and native to Fonoster.

The current reference implementation is:

```text
/root/fonoster-pack/fonoster-docker/test-voiceapp
```

Onelink should study this implementation to move quickly, but should not copy it
as-is into Rails. The production target should be a separate Onelink-managed
voice service.

## Goal

Make Onelink the owner of AI-agent behavior without making Onelink/Rails a
realtime media server.

Target ownership:

```text
Onelink Rails
  owns CRM logic, routing, contacts, conversations, AI config, tools, transcript,
  state reducer, business rules, operator policy

Fonoster
  owns PSTN/SIP, call routing execution, voice app execution, operator SIP dial,
  hangup, provider/Fonoster call events

Onelink AI Voice Service
  owns realtime voice session, Gemini Live websocket, audio streaming,
  barge-in/interruption, AI tool calls, transfer execution
```

Target runtime flow:

```text
PSTN/SIP
-> Fonoster number
-> Fonoster voice-runtime
-> Onelink /internal/voice/inbound/route
-> action=ai, app_ref=<onelink_ai_voice_app_ref>
-> Onelink AI Voice Service
-> Gemini Live
-> transcript/events/tools/results back to Onelink
```

The audio path must stay short:

```text
Fonoster voice app <-> Gemini Live
```

Rails should receive events, transcript, state updates, and tool requests. Rails
should not receive every audio chunk.

## Supported AI Deployment Modes

The Fonoster bridge supports two AI deployment modes:

```text
fonoster_managed  current Gemini AI app running on the Fonoster side
onelink_managed  future Onelink AI Voice Service
```

Both modes use the same route action:

```json
{
  "action": "ai",
  "app_ref": "<selected_ai_fonoster_app_ref>"
}
```

The selected `app_ref` decides which implementation receives the call.

During migration:

```text
fonoster_managed -> app_ref points to current test/prod Fonoster AI app
onelink_managed -> app_ref points to new onelink-ai-voice app
```

Recommended Onelink channel fields:

```json
{
  "ai_mode": "fonoster_managed",
  "fonoster_ai_app_ref": "7b9f0bbd-eac4-46e4-80a8-7b3d5341c9f8",
  "onelink_ai_app_ref": null,
  "fallback_ai_app_ref": "7b9f0bbd-eac4-46e4-80a8-7b3d5341c9f8"
}
```

Switching to Onelink-owned AI should only require changing `ai_mode` and
`app_ref`/`onelink_ai_app_ref`; the rest of the bridge protocol stays the same.

## Why Not Put Gemini Live Inside Rails

Do not make Rails handle live audio streaming.

Reasons:

- Rails adds request middleware, DB, background job, and thread overhead that is
  not useful for per-audio-frame realtime work.
- Gemini Live needs a long-lived low-latency websocket session.
- Interruptions and turn detection need tight audio-loop control.
- A slow database write or CRM action must never block audio.
- Horizontal scaling for voice sessions is easier with a stateless Node/Go voice
  service than with Rails workers.

Rails remains the system of record. The AI voice service remains the realtime
adapter.

## Reference Implementation: test-voiceapp

Onelink should study `test-voiceapp` because it already contains the core
runtime pieces needed for production:

- Fonoster voice app entrypoint.
- Session registry.
- Call answer/hangup.
- Gemini Live websocket integration.
- Realtime audio input/output.
- Greeting mode.
- Transcript collection.
- Tool-call handling shape.
- Transfer-intent detection.
- Transfer execution through `voice.dial(...)`.
- Event buffer and simple HTTP diagnostics.
- Fallback scripted flow when realtime provider is unavailable.

Key file:

```text
/root/fonoster-pack/fonoster-docker/test-voiceapp/index.js
```

Important areas to inspect:

```text
config block
session creation and session registry
runRealtimeVoiceConversation
Gemini Live websocket connection
realtime audio stream handling
tool call handling
transferToLiveAgent
emitSessionEvent
emitBridgeLifecycleEvent
HTTP session/event endpoints
```

Use this as a reference implementation, not the final production service.

## What To Keep From test-voiceapp

Keep these implementation ideas:

- Node service for realtime voice.
- Fonoster voice app endpoint.
- One in-memory session object per active call.
- Gemini Live websocket per active call.
- Async event emission so audio is not blocked.
- Transcript buffering.
- Transfer through `voice.dial(...)`.
- `VOICE_AGENT_TRANSFER_AGENT_AOR` style operator target.
- `transfer_started`, `transfer_answered`, `transfer_completed`,
  `transfer_failed` bridge events.
- Health/session diagnostics.
- Provider fallback path.

## What To Change For Production

Do not ship the current test app unchanged.

Production changes required:

- Rename service to `onelink-ai-voice`.
- Move AI config ownership to Onelink Rails.
- Fetch prompt/model/voice/language/tools from Onelink by `call_ref` or channel.
- Remove hard-coded demo prompts and test messages.
- Remove test-only defaults and smoke-test assumptions.
- Add authenticated calls to Onelink internal APIs.
- Add structured logging with `call_ref`, `conversation_id`, `account_id`.
- Add metrics for latency, session count, Gemini errors, transfer failures.
- Add graceful shutdown for active calls.
- Add rate limits and max call duration.
- Add per-account/provider config isolation.
- Add production secrets management.
- Add circuit breaker/fallback when Onelink context API is slow.

## New Onelink AI Voice Service

Recommended runtime: Node.js.

Reason: the current working realtime code is Node, Fonoster voice app examples
are Node-oriented, and Gemini Live websocket/audio handling is already proven in
the existing service.

Service responsibilities:

1. Accept Fonoster voice sessions.
2. Create a local call session object.
3. Immediately answer the call when the app route starts.
4. Fetch AI context/config from Onelink.
5. Open Gemini Live websocket.
6. Stream caller audio to Gemini.
7. Stream Gemini audio back to caller.
8. Send transcript batches to Onelink.
9. Execute Onelink tools.
10. Transfer to operator when requested.
11. Emit bridge lifecycle events.
12. Hang up or finalize cleanly.

Suggested service endpoints:

```text
GET /healthz
GET /sessions
GET /sessions/:session_id
GET /sessions/:session_id/events
GET /sessions/:session_id/transcript
```

These endpoints are operational diagnostics only. The voice app endpoint remains
the Fonoster voice server, not a public HTTP API.

## Onelink Rails Responsibilities

Onelink Rails should implement the control plane.

### AI Agent Config

Create or extend a model similar to:

```text
AiVoiceAgentConfig
```

Recommended fields:

```text
account_id
channel_id
enabled
fonoster_app_ref
provider
model
voice
language
system_prompt
first_message
greeting_mode
turn_detection
interruptions_enabled
max_duration_sec
max_no_input_retries
business_hours_policy
transfer_enabled
transfer_mode
operator_agent_aor
fallback_mode
tools_enabled
tool_policy
metadata
```

`fonoster_app_ref` should point to the production AI voice app, not the runtime
router app.

### Route Decision

When AI is selected, Onelink returns:

```json
{
  "action": "ai",
  "app_ref": "<onelink_ai_voice_app_ref>",
  "reason": "ai_enabled_for_channel",
  "timeout": 60
}
```

Rules:

- `action=ai` is a business mode.
- `app_ref` is the technical Fonoster target.
- Do not return the inbound `runtime_app_ref` as `app_ref`.
- If AI config is missing or disabled, return `operator`, `app`, or `reject`
  based on channel policy.

### AI Context Endpoint

Add an internal endpoint used by the AI voice service:

```http
GET /internal/voice/ai/context?call_ref=<call_ref>
```

Recommended response:

```json
{
  "call_ref": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "account_id": "1",
  "conversation_id": "123",
  "contact_id": "456",
  "caller_number": "+77066318623",
  "ingress_number": "+18623964686",
  "channel": {
    "id": "channel-id",
    "phone_number": "+18623964686"
  },
  "ai": {
    "provider": "gemini-live",
    "model": "gemini-2.0-flash-live",
    "voice": "default",
    "language": "ru-KZ",
    "system_prompt": "...",
    "first_message": "...",
    "interruptions_enabled": true,
    "max_duration_sec": 900
  },
  "transfer": {
    "enabled": true,
    "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz",
    "message": "I will connect you to a live specialist now."
  },
  "tools": [
    {
      "name": "find_contact",
      "enabled": true
    },
    {
      "name": "create_note",
      "enabled": true
    },
    {
      "name": "request_transfer",
      "enabled": true
    }
  ]
}
```

Performance rule: this endpoint should be fast. Target p95 under `300ms`.

If it is slow or unavailable, the AI voice service should use a cached config or
fallback message, not block audio startup indefinitely.

### Transcript Endpoint

Add an internal endpoint:

```http
POST /internal/voice/ai/transcript
```

Recommended payload:

```json
{
  "call_ref": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "conversation_id": "123",
  "items": [
    {
      "speaker": "caller",
      "text": "I need support",
      "final": true,
      "at": "2026-04-28T09:00:00.000Z"
    },
    {
      "speaker": "ai",
      "text": "I can help you with that.",
      "final": true,
      "at": "2026-04-28T09:00:01.000Z"
    }
  ]
}
```

Performance rule:

- Send batches every `500-1000ms`.
- Send final transcript on call end.
- Do not write every token synchronously to the DB.

### Tool Endpoint

Add one internal tool dispatch endpoint:

```http
POST /internal/voice/ai/tools/:tool_name
```

Examples:

```text
find_contact
create_contact
create_note
update_conversation
create_task
request_transfer
end_call
```

Recommended timeout:

```text
300-800ms for realtime turn-critical tools
2-5s for non-critical async tools
```

If a tool is slow, AI should continue with a fallback response and Onelink can
finish side effects asynchronously.

### Event Ingestion

Onelink already needs:

```http
POST /internal/voice/inbound/event
```

For AI, it must accept:

```text
ai_ringing
ai_answered
transfer_started
transfer_answered
transfer_completed
transfer_failed
session_completed
session_failed
```

It must store raw unknown fields and update canonical call state through a
state reducer.

## Fonoster Responsibilities

Fonoster side should remain small and deterministic.

1. Keep `voice-runtime` as inbound dispatcher.
2. Keep `telephony-bridge` as normalized event bridge.
3. Register production `onelink-ai-voice` as a real Fonoster application.
4. Store the production AI app ref in Onelink as `ai_app_ref`.
5. Route inbound AI calls only through `action=ai`.
6. Keep `runtime_app_ref` only as the router app for inbound calls.
7. Never use `runtime_app_ref` as the AI target for the same inbound route.
8. Keep operator transfer target as SIP AOR, e.g.
   `sip:1001@operator.cloud.vconsult.kz`.
9. Emit lifecycle fields:
   `routingMode`, `callDirection`, `currentStatus`, `answeredBy`, `endedBy`,
   `endReason`, `terminal`.
10. Keep snake_case aliases for Rails compatibility.

## Fast Path Rules

The following rules are required for low latency:

1. Do not send audio chunks to Rails.
2. Do not wait for Rails before every Gemini turn.
3. Fetch context once at call start, then cache it for the call.
4. Refresh context only for explicit tool calls or transfer decisions.
5. Send transcript in batches, not token-by-token DB writes.
6. Send events asynchronously.
7. Use short timeouts for Onelink APIs.
8. Use fallback config when Onelink context API is slow.
9. Keep the AI voice service close to Fonoster in network topology.
10. Keep Gemini Live websocket open for the active session only.

Recommended latency targets:

```text
route decision p95: <= 300ms
AI context fetch p95: <= 300ms
tool call realtime p95: <= 800ms
transcript batch interval: 500-1000ms
first AI audio after answer: as low as provider allows, target <= 1500ms
```

## Configuration

The AI voice service needs two kinds of configuration:

- Runtime execution env for the service/container.
- Business configuration stored in Onelink Rails and returned by the context
  endpoint.

Do not put customer-specific prompts, transfer policy, business hours, or tool
policy only in container env. Those belong to Onelink database/config so they
can be changed per channel without redeploying the realtime service.

### Onelink AI Voice Service Env

Use this as the production env template for the future `onelink-ai-voice`
service. Values are shown as placeholders except current non-secret defaults.

```env
# Service identity
ONELINK_AI_VOICE_SERVICE_NAME=onelink-ai-voice
NODE_ENV=production
LOG_LEVEL=info

# Fonoster voice app runtime
VOICE_AGENT_GRPC_PORT=50061
VOICE_AGENT_SKIP_IDENTITY=false
VOICE_AGENT_IDENTITY_ADDRESS=cloud.vconsult.kz:443

# Optional diagnostics API
VOICE_AGENT_API_PORT=8081
VOICE_AGENT_API_TOKEN=<secret-or-empty-if-private-network-only>
VOICE_AGENT_API_CORS_ORIGIN=<internal-origin-or-empty>
VOICE_AGENT_API_HEARTBEAT_MS=15000
VOICE_AGENT_API_EVENT_BUFFER_LIMIT=300
VOICE_AGENT_API_TRANSCRIPT_LIMIT=300

# Session limits
VOICE_AGENT_SESSION_TTL_MS=3600000
VOICE_AGENT_SESSION_HISTORY=20
VOICE_AGENT_IDLE_HANGUP_MS=240000
VOICE_AGENT_MAX_TURNS=20
VOICE_AGENT_MAX_HISTORY_MESSAGES=30
VOICE_AGENT_MAX_NO_INPUT_RETRIES=2

# Fonoster bridge event sink
VOICE_AGENT_BRIDGE_BASE_URL=http://telephony-bridge:3100
VOICE_AGENT_BRIDGE_SHARED_SECRET=<same-as-TELEPHONY_BRIDGE_SHARED_SECRET>
VOICE_AGENT_BRIDGE_EVENT_PATH=/internal/voice/inbound/event

# Onelink control plane
ONELINK_INTERNAL_BASE_URL=<https://app.one-link.kz-or-internal-url>
ONELINK_INTERNAL_API_TOKEN=<secret>
ONELINK_AI_CONTEXT_PATH=/internal/voice/ai/context
ONELINK_AI_TRANSCRIPT_PATH=/internal/voice/ai/transcript
ONELINK_AI_TOOL_PATH_PREFIX=/internal/voice/ai/tools
ONELINK_API_TIMEOUT_MS=800
ONELINK_CONTEXT_TIMEOUT_MS=300
ONELINK_TRANSCRIPT_BATCH_MS=750
ONELINK_TRANSCRIPT_FINAL_FLUSH_TIMEOUT_MS=2000

# Gemini Live provider
VOICE_AGENT_REALTIME_PROVIDER=gemini-live
VOICE_AGENT_REALTIME_API_KEY=<secret>
VOICE_AGENT_REALTIME_BASE_URL=wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent
VOICE_AGENT_REALTIME_MODEL=<gemini-live-model>
VOICE_AGENT_REALTIME_VOICE=<voice-or-empty>
VOICE_AGENT_REALTIME_LANGUAGE=<language-or-empty>
VOICE_AGENT_REALTIME_INPUT_RATE=16000
VOICE_AGENT_REALTIME_OUTPUT_RATE=24000
VOICE_AGENT_REALTIME_CALL_RATE=8000
VOICE_AGENT_REALTIME_MAX_DURATION_MS=900000
VOICE_AGENT_REALTIME_GREETING_MODE=tts
VOICE_AGENT_REALTIME_TURN_DETECTION=semantic_vad
VOICE_AGENT_REALTIME_INTERRUPTS=true
VOICE_AGENT_REALTIME_LOG_PROVIDER_EVENTS=false

# Fallback and transfer execution
VOICE_AGENT_FALLBACK_MODE=scripted
VOICE_AGENT_FALLBACK_MESSAGE=<fallback-message-from-onelink-or-default>
VOICE_AGENT_NO_INPUT_MESSAGE=<no-input-message-from-onelink-or-default>
VOICE_AGENT_GOODBYE_MESSAGE=<goodbye-message-from-onelink-or-default>
VOICE_AGENT_TRANSFER_MESSAGE=<transfer-message-from-onelink-or-default>
VOICE_AGENT_TRANSFER_AGENT_AOR=<default-operator-aor-or-empty>

# Legacy non-realtime LLM fallback, optional
VOICE_AGENT_LLM_PROVIDER=
VOICE_AGENT_LLM_BASE_URL=
VOICE_AGENT_LLM_API_KEY=<secret-or-empty>
VOICE_AGENT_LLM_MODEL=
VOICE_AGENT_LLM_TIMEOUT_MS=120000
VOICE_AGENT_LLM_STREAMING=false
```

Secrets in this block:

```text
VOICE_AGENT_API_TOKEN
VOICE_AGENT_BRIDGE_SHARED_SECRET
ONELINK_INTERNAL_API_TOKEN
VOICE_AGENT_REALTIME_API_KEY
VOICE_AGENT_LLM_API_KEY
```

Do not commit real values. Keep them in secret storage or deployment env.

### Current Fonoster Reference Values

For the current reference implementation, these are the useful non-secret
values from the Fonoster `.env`:

```env
VOICE_AGENT_BRIDGE_BASE_URL=http://telephony-bridge:3100
VOICE_AGENT_BRIDGE_EVENT_PATH=/internal/voice/inbound/event
VOICE_AGENT_REALTIME_PROVIDER=gemini-live
VOICE_AGENT_REALTIME_BASE_URL=wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent
VOICE_AGENT_REALTIME_MAX_DURATION_MS=900000
VOICE_AGENT_REALTIME_LOG_PROVIDER_EVENTS=false
VOICE_AGENT_TRANSFER_AGENT_AOR=sip:1001@operator.cloud.vconsult.kz
```

Current secret values must be copied only through secure deployment channels:

```text
VOICE_AGENT_REALTIME_API_KEY
TELEPHONY_BRIDGE_SHARED_SECRET / VOICE_AGENT_BRIDGE_SHARED_SECRET
```

### Onelink-Owned Business Config

Onelink should own business config:

```text
prompt
first message
model selection
voice
language
business hours
transfer rules
tool rules
fallback policy
per-channel AI enabled flag
```

Recommended Onelink channel fields for AI:

```json
{
  "ai_enabled": true,
  "ai_mode": "fonoster_managed",
  "fonoster_ai_app_ref": "7b9f0bbd-eac4-46e4-80a8-7b3d5341c9f8",
  "onelink_ai_app_ref": null,
  "fallback_ai_app_ref": "7b9f0bbd-eac4-46e4-80a8-7b3d5341c9f8",
  "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz",
  "model": "<gemini-live-model>",
  "voice": "<voice>",
  "language": "ru-KZ",
  "interruptions_enabled": true,
  "max_duration_sec": 900,
  "transcript_enabled": true,
  "tools_enabled": true
}
```

When Onelink switches to its own AI voice service:

```json
{
  "ai_mode": "onelink_managed",
  "onelink_ai_app_ref": "<new_onelink_ai_voice_app_ref>",
  "fallback_ai_app_ref": "7b9f0bbd-eac4-46e4-80a8-7b3d5341c9f8"
}
```

## Migration Steps

1. Onelink reads `test-voiceapp/index.js` and identifies reusable realtime
   pieces.
2. Create a new service repository/package: `onelink-ai-voice`.
3. Copy the minimum voice runtime/Gemini pieces from `test-voiceapp`.
4. Replace local prompt/config with Onelink `/internal/voice/ai/context`.
5. Replace local tool handling with Onelink tool endpoint calls.
6. Keep local session registry and Gemini Live audio loop.
7. Add transcript batching to Onelink.
8. Add transfer events to bridge/Onelink.
9. Register `onelink-ai-voice` as a Fonoster application.
10. Store its app ref in Onelink as `ai_app_ref`.
11. Route one test number to AI through feature flag.
12. Run smoke matrix.
13. Enable for production channels gradually.

## Smoke Matrix

Required tests:

1. Inbound call routes to AI and starts conversation.
2. AI greeting is heard.
3. Caller speech reaches Gemini.
4. Gemini response audio returns to caller.
5. Transcript reaches Onelink conversation.
6. Caller hangs up before AI answer.
7. Caller hangs up during AI conversation.
8. AI ends call.
9. AI requests transfer to operator.
10. Operator answers transfer.
11. Operator does not answer transfer.
12. Gemini websocket fails and fallback works.
13. Onelink context endpoint is slow and fallback config works.
14. Duplicate events do not duplicate call sessions.
15. Terminal state is not overwritten by late events.
16. Outbound call uses AI app ref.
17. Outbound AI answered call completes normally.
18. Outbound no-answer/busy/failed are distinct.

## Production Readiness Checklist

Onelink:

- AI config model exists.
- Call session model exists.
- Raw event storage exists.
- State reducer exists.
- Terminal guard exists.
- Route decision returns `action=ai`.
- Context endpoint exists.
- Transcript endpoint exists.
- Tool endpoint exists.
- CRM UI shows AI state separately from app/operator.

AI voice service:

- Uses Onelink context.
- Uses Gemini Live.
- Does not route audio through Rails.
- Sends transcript batches.
- Sends lifecycle events.
- Supports transfer.
- Has health and diagnostics.
- Has graceful shutdown.
- Has timeouts and fallback.

Fonoster:

- Production AI app is registered.
- Onelink stores production `ai_app_ref`.
- `runtime_app_ref` remains router only.
- Bridge events contain canonical lifecycle fields.
- Transfer target is configured.

## Final Architecture Rule

The production system should be:

```text
Onelink owns business logic.
Fonoster owns telephony execution.
Onelink AI Voice Service owns realtime Gemini audio.
telephony-bridge owns normalized event delivery.
```

This is the fastest and cleanest split. It makes AI native to Onelink without
turning Onelink Rails into a realtime audio service.
