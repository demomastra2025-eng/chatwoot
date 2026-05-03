# Onelink Fonoster Voice Contract

Canonical sync document for Onelink, Fonoster, and the Onelink AI Voice Service.
Last updated: 2026-05-03.

Use this document as the source of truth for the production voice/call contract.

## Active Documents

Only these documents are active for Fonoster synchronization:

- `ONELINK_FONOSTER_VOICE_CONTRACT.md` - canonical behavior, payloads, ids, retries, fallback, transfer, finalization.
- `ONELINK_CRM_GEMINI_SYNC_HANDOFF.md` - cross-team handoff checklist for Onelink CRM/Gemini synchronization.
- `ONELINK_EXTERNAL_GEMINI_LIVE_VOICEAPP.md` - deployment shape for the Onelink-hosted Gemini Live VoiceApp.
- `ONELINK_BRIDGE_API_CONTRACT.md` - Onelink to Fonoster bridge command API and inbound route/event callbacks.

Everything else in `fonoster-docs/` is historical background unless explicitly copied into one of the active documents above.

## Production Split

```text
Fonoster
  owns PSTN/SIP, inbound call delivery, outbound createCall execution,
  bidirectional media bridge, dial/transfer execution, hangup, recording,
  technical call events, app refs, trunks, numbers, domains, agents.

Onelink AI Voice Service
  runs next to Onelink as a separate Node service.
  owns Fonoster VoiceServer endpoint, one Gemini Live websocket per active call,
  realtime audio loop, resampling, barge-in, audio buffering, Gemini tool calls,
  transcript buffering, and low-level call actions after Rails authorizes them.

Onelink Rails
  owns CRM state, contacts, conversations, routing policy, AI config, prompts,
  tools, operator selection policy, fallback policy, transcript storage,
  summaries, final business status, and audit state.
```

Rails must not receive realtime audio frames. Rails receives JSON only.

## What Fonoster Team Needs

Give Fonoster team only:

- private `onelink-ai-voice` endpoint reachable from Fonoster: `<private-host>:50061`
- optional private health endpoint if exposed: `<private-host>:8081`
- Fonoster `EXTERNAL` application ref pointing to that endpoint, or permission to create/update it
- technical routing requirement: inbound AI route must use the Onelink AI app ref
- technical fallback rule if the selected app endpoint cannot be reached
- event identity/retry/finalization rules from this document
- requirement that the Fonoster image supports bidirectional stream `AUDIO_IN` and `AUDIO_OUT`

Do not give Fonoster team:

- Gemini API keys
- Rails internal auth secret
- CRM database access
- prompt templates
- customer context rules
- CRM tool implementation
- operator selection/business policy beyond executable route and transfer targets returned by Onelink

## Secrets Boundary

Gemini keys live only on the Onelink AI Voice Service side.

Remove these from the Fonoster server when the Onelink-hosted app is active:

- `GEMINI_API_KEY`
- `GOOGLE_API_KEY`
- `VOICE_AGENT_REALTIME_API_KEY`
- prompt/customer/tool config for the AI agent
- local `test-voiceapp` as the production target

Fonoster keeps only technical execution config: app refs, bridge URL/secret, trunks, numbers, SIP resources, and technical fallback targets.

## Network Boundary

Fonoster currently connects to `EXTERNAL` voice apps over gRPC. The Onelink AI Voice Service endpoint must be private.

Allowed production options:

1. Private network, WireGuard, Tailscale, private VPC, or equivalent.
2. Temporary controlled test: expose TCP `50061` only to the Fonoster server IP.
3. Public internet only after TLS/mTLS is implemented and tested for the Fonoster voice client and the Onelink VoiceServer.

Do not expose `50061` openly to the internet.

Minimum connectivity check before route/app ref switch:

```text
Fonoster server -> onelink-ai-voice TCP 50061
```

## Canonical Call Paths

Inbound AI call:

```text
PSTN/SIP
-> Fonoster number
-> Fonoster runtime/bridge asks Onelink for route
-> Onelink returns action=ai with onelink_ai_app_ref
-> Fonoster connects call to Onelink AI Voice Service
-> Onelink AI Voice Service opens Gemini Live
-> caller audio -> Gemini
-> Gemini audio -> caller
-> events/transcripts/finalize -> Rails JSON endpoints
```

Outbound AI call:

```text
Onelink Rails
-> Fonoster bridge POST /telephony/calls/outbound
-> Fonoster Calls.createCall with appRef = onelink_ai_app_ref
-> Fonoster connects call to Onelink AI Voice Service
-> Gemini Live voice loop
-> events/transcripts/finalize -> Rails JSON endpoints
```

Operator route:

```text
Fonoster inbound call
-> Onelink route decision action=operator
-> Fonoster dials agent_aor
-> answer/no-answer/busy/failed events -> Rails
```

AI transfer to operator:

```text
Gemini tool_call
-> onelink-ai-voice
-> Rails /internal/voice/ai/tools/:name
-> Rails returns action=transfer and operator_agent_aor
-> onelink-ai-voice executes voice.dial(...)
-> transfer_requested and transfer_result events -> Rails
-> finalize as transferred or operator_unavailable
```

## Required Fonoster Core Capability

The active Fonoster image must support bidirectional voice streams:

- caller audio to app as `StreamMessageType.AUDIO_IN`
- app audio to caller as `StreamMessageType.AUDIO_OUT`
- stable `streamRef`
- cleanup on `StopStream` and `StasisEnd`

If only `AUDIO_IN` works, Gemini will hear the caller but the caller will not hear Gemini.

## Identifiers

Every cross-service request must carry stable ids when available.

```text
call_id
  Onelink canonical call/session id.

provider_call_id
  Fonoster call reference. In legacy payloads this can be call_ref/callRef/ref.

media_session_ref
  Fonoster media/channel/stream session reference, useful for debugging.

ai_session_id
  Onelink AI Voice Service session id. One active Gemini websocket per active call.

conversation_id
  Onelink conversation linked to the call.

event_id
  Stable id for one event. Retries must reuse the same event_id.

event_seq
  Monotonic integer inside one ai_session_id/provider_call_id. Starts at 1.

request_id
  Trace id for one delivery attempt.

attempt
  Delivery attempt number. Starts at 1 and increments on retry.
```

Minimum event identity:

```json
{
  "event_id": "evt_01JZ...",
  "event_seq": 7,
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "ai_session_id": "ai_sess_01JZ...",
  "call_id": "call_123"
}
```

If `call_id` is not known yet, send `provider_call_id` and `ai_session_id`. Rails must attach the event after the call row exists.

## Auth Headers

### Fonoster bridge to Rails

```http
Content-Type: application/json
X-Account-Id: <onelink account id>
X-Request-Id: <uuid>
Authorization: Bearer <bridge shared token>
```

Compatibility headers accepted by Onelink bridge controllers:

```http
X-Bridge-Secret: <token>
X-Telephony-Secret: <token>
Authorization: Bearer <token>
```

### Onelink AI Voice Service to Rails

```http
Content-Type: application/json
X-Request-Id: <uuid>
Authorization: Bearer <onelink internal voice token>
```

For `/event` and `/finalize` also send:

```http
X-Event-Id: <event_id>
X-Idempotency-Key: <event_id or finalize key>
X-Event-Attempt: <attempt number>
```

Current Rails code accepts the internal voice token from these env aliases:

```text
VOICE_AGENT_ONELINK_AI_SHARED_SECRET
ONELINK_AI_VOICE_INTERNAL_TOKEN
AI_VOICE_INTERNAL_TOKEN
ONELINK_INTERNAL_SECRET
ONELINK_INTERNAL_TOKEN
```

Use the same value on Rails and `onelink-ai-voice`.

## Rails API Surface

Bridge callbacks from Fonoster:

```text
POST /internal/voice/inbound/route
POST /internal/voice/inbound/event
POST /telephony/internal/events
```

AI runtime callbacks from `onelink-ai-voice`:

```text
POST /internal/voice/ai/context
POST /internal/voice/ai/transcript
POST /internal/voice/ai/tools/:name
POST /internal/voice/ai/control
POST /internal/voice/ai/event
POST /internal/voice/ai/finalize
```

`/event` and `/finalize` are compatibility adapter endpoints and must stay idempotent.

## Inbound Route Decision

Endpoint:

```http
POST /internal/voice/inbound/route
```

Request shape:

```json
{
  "event_id": "evt_route_01JZ...",
  "event_type": "inbound_route_requested",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "call_ref": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "media_session_ref": "asterisk-channel-or-media-session",
  "from": "+77066318623",
  "to": "+18623964686",
  "direction": "inbound",
  "ingress_number": "+18623964686",
  "app_ref": "runtime-router-app-ref",
  "started_at": "2026-05-03T12:00:00.000Z",
  "metadata": {}
}
```

AI response:

```json
{
  "action": "ai",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "app_ref": "<onelink_ai_app_ref>",
  "ai_session_mode": "onelink_managed",
  "reason": "ai_enabled",
  "timeout": 60,
  "fallback": {
    "on_ai_unavailable": "operator",
    "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz",
    "fallback_app_ref": null
  }
}
```

Operator response:

```json
{
  "action": "operator",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "agent_aor": "sip:1001@operator.cloud.vconsult.kz",
  "reason": "operator_route",
  "timeout": 30
}
```

Reject response:

```json
{
  "action": "reject",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "message": "We are currently closed.",
  "reason": "business_hours_closed"
}
```

Business rejection must return HTTP `200` with `action=reject`. Non-2xx means technical failure.

Route rules:

- `action=ai` must include a real AI app ref.
- Do not return the current runtime/router app ref as the target AI/app ref for the same inbound call.
- Operator route must include an executable SIP AOR.
- Onelink route decisions are authoritative. Fonoster may only apply technical fallback if Onelink is unavailable or the selected target cannot be reached.

## AI Context

Endpoint:

```http
POST /internal/voice/ai/context
```

Request:

```json
{
  "call_id": "call_123",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "media_session_ref": "asterisk-channel-or-media-session",
  "ai_session_id": "ai_sess_01JZ...",
  "conversation_id": "conv_123",
  "from": "+77066318623",
  "to": "+18623964686",
  "direction": "inbound",
  "started_at": "2026-05-03T12:00:00.000Z"
}
```

Response:

```json
{
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "contact_id": "contact_123",
  "language": "ru-RU",
  "model": "gemini-3.1-flash-live-preview",
  "voice": "Sulafat",
  "system_prompt": "Short phone assistant instructions...",
  "max_output_tokens": 120,
  "temperature": 0.3,
  "tools": [
    {
      "name": "transfer_to_operator",
      "description": "Ask Onelink whether this call should be transferred."
    },
    {
      "name": "end_call",
      "description": "End the call after the user is done."
    }
  ],
  "fallback_policy": {
    "on_gemini_unavailable": "operator",
    "on_stream_error": "operator",
    "on_operator_unavailable": "finalize"
  },
  "operator": {
    "agent_aor": "sip:1001@operator.cloud.vconsult.kz",
    "timeout": 30
  }
}
```

Rails owns this response. Fonoster must not invent prompt, tools, CRM context, model, or transfer policy.

## Event Adapter

Endpoint:

```http
POST /internal/voice/ai/event
```

Common event shape:

```json
{
  "event_id": "evt_01JZ...",
  "event_seq": 4,
  "event_type": "stream_started",
  "provider": "fonoster",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "media_session_ref": "asterisk-channel-or-media-session",
  "ai_session_id": "ai_sess_01JZ...",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "occurred_at": "2026-05-03T12:00:02.000Z",
  "attempt": 1,
  "payload": {}
}
```

Response:

```json
{
  "status": "ok",
  "event_id": "evt_01JZ...",
  "call_id": "call_123",
  "conversation_id": "conv_123"
}
```

Required AI event types:

```text
call_started
stream_started
transcript_delta
tool_started
tool_completed
tool_failed
transfer_requested
transfer_result
recording_ready
error
call_ended
```

Transfer results:

```text
answered
no_answer
busy
failed
cancelled
```

Error scopes:

```text
gemini_live
voice_stream
rails_context
rails_tool
transfer
recording
unknown
```

## Finalize

Endpoint:

```http
POST /internal/voice/ai/finalize
```

`finalize` is the canonical terminal business event for the AI voice session. It must be idempotent.

Allowed final statuses:

```text
completed
transferred
failed
caller_hung_up
operator_unavailable
rejected
cancelled
timeout
```

Request:

```json
{
  "event_id": "evt_finalize_01JZ...",
  "event_seq": 99,
  "event_type": "finalize",
  "call_id": "call_123",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "media_session_ref": "asterisk-channel-or-media-session",
  "ai_session_id": "ai_sess_01JZ...",
  "conversation_id": "conv_123",
  "status": "transferred",
  "started_at": "2026-05-03T12:00:00.000Z",
  "ended_at": "2026-05-03T12:02:00.000Z",
  "duration_ms": 120000,
  "reason": "operator_answered",
  "final_transcript": [
    {
      "speaker": "caller",
      "text": "I want to talk to an operator.",
      "at": "2026-05-03T12:01:00.000Z"
    },
    {
      "speaker": "assistant",
      "text": "I will connect you now.",
      "at": "2026-05-03T12:01:03.000Z"
    }
  ],
  "summary": "Caller requested an operator and was transferred.",
  "transfer_result": {
    "requested": true,
    "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz",
    "result": "answered",
    "dial_started_at": "2026-05-03T12:01:10.000Z",
    "answered_at": "2026-05-03T12:01:18.000Z",
    "duration_ms": 8000
  },
  "recording_url": null,
  "error_code": null,
  "error_message": null,
  "attempt": 1
}
```

Response:

```json
{
  "status": "ok",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "already_finalized": false
}
```

Duplicate finalize with the same terminal payload must return HTTP `2xx` and `already_finalized=true`.

Conflicting duplicate finalize must not break retries with `5xx`; Rails should keep the first terminal state, store an operational conflict event, and return `2xx` with the stored state.

## Idempotency And Retry

Delivery is at least once.

Sender rules:

- retry transient failures
- reuse the same `event_id` and `X-Idempotency-Key` on retry
- increment `attempt`
- never generate a new event id for the same event

Rails dedupe priority:

1. `event_id`
2. `(provider_call_id, event_id)` as safety scope
3. `(ai_session_id, event_seq)` for AI runtime compatibility

Retry on:

```text
network timeout
connection reset
HTTP 408
HTTP 409 when retryable
HTTP 425
HTTP 429
HTTP 500
HTTP 502
HTTP 503
HTTP 504
```

Do not retry normal validation/auth errors:

```text
HTTP 400
HTTP 401
HTTP 403
HTTP 404
HTTP 422
```

Recommended event retry schedule:

```text
1s, 5s, 15s, 60s, 5m, 15m, with jitter
```

Targets:

```text
route decision p95: <= 300ms
route hard timeout: 1500ms
event/finalize p95: <= 300ms
event/finalize hard timeout: 2000ms
AI context p95: <= 300ms
realtime tool p95: <= 800ms
```

## Tool Boundary

Fonoster must not implement CRM tools.

Allowed low-level call actions after Onelink authorizes them:

```text
transfer
end_call
hold
playback, only if explicitly enabled by Onelink
```

Everything else belongs to Onelink:

- contact lookup
- conversation creation
- customer context
- prompt generation
- tool policy
- operator selection
- escalation rules
- CRM writes
- scheduling
- summaries
- transcript storage
- final business state

Transfer tool result from Rails:

```json
{
  "ok": true,
  "action": "transfer",
  "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz",
  "reason": "caller_requested_operator",
  "timeout": 30
}
```

End call tool result from Rails:

```json
{
  "ok": true,
  "action": "end_call",
  "reason": "caller_finished"
}
```

If Rails returns a CRM-only result, the voice service must not invent a transfer.

## Fallback Cases

Fallback policy is owned by Onelink. Fonoster may only do technical fallback when Onelink cannot be reached or a selected target cannot be executed.

Gemini unavailable:

```text
onelink-ai-voice emits error scope=gemini_live
onelink-ai-voice applies Rails fallback_policy
if policy=operator, transfer to Onelink-approved operator target
if no fallback exists, finalize failed
```

Onelink AI Voice Service unavailable:

```text
Fonoster cannot connect selected EXTERNAL app endpoint
Fonoster uses only route response technical fallback or cached safe policy
Fonoster emits error event when possible
if no fallback exists, reject/end safely
```

Rails context timeout:

```text
onelink-ai-voice times out quickly
no audio callback waits on Rails
apply configured fallback policy
emit error scope=rails_context
finalize or transfer according to policy
```

Operator unavailable:

```text
emit transfer_result no_answer/busy/failed
finalize operator_unavailable unless Rails explicitly configured another fallback
```

Stream broken:

```text
emit error scope=voice_stream
stop Gemini loop
apply fallback policy
finalize failed if no fallback exists
```

Recording failure:

```text
emit error scope=recording
finalize must not wait for recording
recording_ready may update the call after terminal state
```

## Recording Rules

Recording is a technical artifact from Fonoster.

Rules:

- recording may arrive after finalize
- `recording_ready` must update the existing call row
- missing recording must not block finalize
- recording failure must be an `error` event, not a broken call finalization

Recommended payload:

```json
{
  "event_type": "recording_ready",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "call_id": "call_123",
  "recording_ref": "rec_123",
  "recording_url": "https://recordings.example/call_123.wav",
  "duration_ms": 120000,
  "format": "wav"
}
```

## Production Readiness Checklist

Code/contract readiness:

1. Rails exposes `/internal/voice/ai/event`.
2. Rails exposes `/internal/voice/ai/finalize`.
3. `finalize` is idempotent.
4. Rails deduplicates events by `event_id` or compatible idempotency key.
5. `onelink-ai-voice` emits `event_seq`.
6. Transfer emits `transfer_requested` and `transfer_result`.
7. Recording can update after finalize.
8. No raw audio reaches Rails.

Deployment readiness:

1. Fonoster app endpoint points to `onelink-ai-voice`, not local `test-voiceapp`.
2. TCP `50061` is reachable from Fonoster and private from the public internet.
3. Running Fonoster image has bidirectional stream support.
4. Gemini keys exist only on the Onelink side.
5. Rails and `onelink-ai-voice` use the same internal voice token.
6. Outbound AI calls use the Onelink AI app ref.
7. Gemini outage fallback is tested.
8. Onelink AI Voice Service outage fallback is tested.
9. Operator no-answer path finalizes `operator_unavailable`.
10. One inbound and one outbound live smoke call pass end to end.

## Values To Fill For Fonoster Sync

These are deployment values, not source-code constants:

```text
onelink_ai_voice_private_host=<private host or IP reachable from Fonoster>
onelink_ai_voice_grpc_endpoint=<private host>:50061
onelink_ai_voice_health_endpoint=<private host>:8081, optional
fonoster_onelink_ai_app_ref=<Fonoster EXTERNAL app ref pointing to onelink-ai-voice>
operator_agent_aor=<production SIP AOR for fallback/transfer>
technical_fallback=<operator|reject|fallback_app_ref>
```

## Final Rule

```text
Fonoster executes calls.
Onelink AI Voice Service runs Gemini Live realtime audio.
Onelink Rails owns business truth.
```

This is the native, reliable, scalable split for production voice agents.
