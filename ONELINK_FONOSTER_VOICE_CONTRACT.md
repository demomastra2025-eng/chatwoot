# Onelink Fonoster Voice Contract

Canonical sync document for Onelink, Fonoster, and OneLink-owned voice runtimes.
Last updated: 2026-05-15.

Use this document as the source of truth for the production voice/call/recording contract.

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
  executes telecom: PSTN/SIP, inbound call delivery, outbound createCall,
  routing to the selected OneLink runtime, media handoff, dial/transfer,
  hangup, technical lifecycle, app refs, trunks, numbers, domains, agents.

OneLink voice runtimes
  own the media path for recordable calls. They receive both audio directions,
  write OneLink-owned recordings, upload to OneLink storage, emit recording
  lifecycle events, and run role-specific media logic.

  Roles:
    onelink-ai-voice       -> AI/Gemini Live calls
    onelink-operator-voice -> operator calls
    onelink-app-voice      -> app-flow calls

  These roles may initially be one shared runtime/codebase with different modes
  and app refs. Architecturally they are separate responsibilities.

Onelink Rails / Chatwoot
  owns CRM truth: contacts, conversations, routing policy, AI config, prompts,
  tools, operator selection policy, fallback policy, recording metadata,
  retention, permissions, signed playback/download URLs, UI, audit, summaries,
  transcripts, and final business status.
```

Rails must not receive realtime audio frames. Rails receives JSON only.

Main rule: for any call requiring OneLink-owned recording, the media path must pass through the selected OneLink voice runtime. Fonoster must not direct-bridge around the OneLink runtime for recordable calls.

## What Fonoster Team Needs

Give Fonoster team only:

- private OneLink runtime endpoints reachable from Fonoster:
  - `onelink-ai-voice`: `<private-host>:50061` or configured AI app endpoint
  - `onelink-operator-voice`: `<private-host>:<operator-runtime-port>` or configured operator app endpoint
  - `onelink-app-voice`: `<private-host>:<app-runtime-port>` or configured app endpoint
- optional private health endpoints if exposed
- Fonoster `EXTERNAL` app refs pointing to those endpoints, or permission to create/update them
- technical routing requirement: `ai`, `operator`, `app`, and `transfer` routes must target the corresponding OneLink runtime when recording is required
- technical fallback rule if the selected app endpoint cannot be reached
- event identity/retry/finalization rules from this document
- requirement that the Fonoster image/media topology supports distinguishable `audio_in` and `audio_out` directions, stable `stream_ref`, and `media_session_ref`

Do not give Fonoster team:

- Gemini API keys
- Rails internal auth secret
- storage credentials
- CRM database access
- prompt templates
- customer context rules
- CRM tool implementation
- retention, permission, signed-URL, or audit policy
- operator selection/business policy beyond executable route and transfer targets returned by Onelink

## Secrets Boundary

Gemini keys live only on the Onelink AI Voice Service side.

Remove these from the Fonoster server when the Onelink-hosted app is active:

- `GEMINI_API_KEY`
- `GOOGLE_API_KEY`
- `VOICE_AGENT_REALTIME_API_KEY`
- prompt/customer/tool config for the AI agent
- local `test-voiceapp` as the production target

Fonoster keeps only technical execution config: app refs, bridge URL/secret, trunks, numbers, SIP resources, and technical fallback targets. Recording files, storage credentials, retention logic, permanent playback URLs, and audit policy stay on the OneLink side.

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
-> Fonoster asks OneLink for route
-> OneLink returns action=ai with onelink_ai_app_ref
-> Fonoster connects call to onelink-ai-voice
-> onelink-ai-voice opens Gemini Live
-> caller/local audio -> Gemini
-> Gemini audio -> caller/local
-> OneLink runtime writes/uploads recording when enabled
-> events/transcripts/finalize/recording lifecycle -> Rails JSON endpoints
```

Inbound operator route:

```text
PSTN/SIP
-> Fonoster number
-> Fonoster asks OneLink for route
-> OneLink returns action=operator with onelink_operator_app_ref/agent_aor
-> Fonoster connects call to onelink-operator-voice
-> onelink-operator-voice dials/bridges operator target
-> caller/local audio and operator/remote audio stay visible to OneLink runtime
-> OneLink runtime writes/uploads recording when enabled
-> telecom + recording lifecycle -> Rails JSON endpoints
```

Inbound app route:

```text
PSTN/SIP
-> Fonoster number
-> Fonoster asks OneLink for route
-> OneLink returns action=app with onelink_app_ref/app target metadata
-> Fonoster connects call to onelink-app-voice
-> onelink-app-voice executes or hands to the app flow while staying in the media path
-> caller/local audio and app/remote audio stay visible to OneLink runtime
-> OneLink runtime writes/uploads recording when enabled
-> telecom + recording lifecycle -> Rails JSON endpoints
```

Outbound calls:

```text
Onelink Rails
-> Fonoster bridge POST /telephony/calls/outbound with selected app ref/mode
-> Fonoster Calls.createCall
-> Fonoster connects call to selected OneLink runtime
-> selected runtime connects AI/operator/app target while staying in the media path
-> OneLink runtime writes/uploads recording when enabled
-> events/transcripts/finalize/recording lifecycle -> Rails JSON endpoints
```

AI transfer to operator:

```text
Gemini tool_call
-> onelink-ai-voice
-> Rails /internal/voice/ai/tools/:name
-> Rails returns action=transfer and operator_agent_aor/runtime target
-> transfer continues through the agreed OneLink runtime when recording must continue
-> transfer_requested and transfer_result events -> Rails
-> recording continues or closes according to the agreed transfer policy
-> finalize as transferred or operator_unavailable
```

Direct bridge rule:

```text
For recordable calls, Fonoster must not bridge caller <-> operator/app directly
in a way that removes the OneLink runtime from the media path.
```

## Required Fonoster Core Capability

The active Fonoster image and media topology must support recordable bidirectional voice streams:

- caller/local audio to the selected OneLink runtime as `audio_in` / `StreamMessageType.AUDIO_IN`
- remote audio from AI/operator/app to the selected OneLink runtime as `audio_out` / `StreamMessageType.AUDIO_OUT`, or an equivalent separately identifiable direction
- stable `stream_ref` when available
- stable `media_session_ref` when available
- direction (`inbound`/`outbound`) and routing mode (`ai`/`operator`/`app`/`transfer`) in the technical context
- cleanup on `StopStream`, `StasisEnd`, hangup, failed, no-answer, busy, and transfer terminal events

If a mode does not expose both audio directions to the OneLink runtime, OneLink-owned stereo recording for that mode is impossible until media topology is changed. This is a Fonoster media-topology gap, not a reason to move recording ownership/storage into Fonoster.

## Identifiers

Every cross-service request must carry stable ids when available.

```text
call_id
  Onelink canonical call/session id.

provider_call_id
  Fonoster call reference. In legacy payloads this can be call_ref/callRef/ref.

media_session_ref
  Fonoster media/channel/stream session reference, useful for debugging.

stream_ref
  Fonoster stream reference when available.

mode / routing_mode
  Selected runtime mode: ai, operator, app, or transfer.

direction
  Call direction: inbound or outbound.

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

AI/runtime callbacks from OneLink voice runtimes:

```text
POST /internal/voice/ai/context
POST /internal/voice/ai/transcript
POST /internal/voice/ai/tools/:name
POST /internal/voice/ai/control
POST /internal/voice/ai/event
POST /internal/voice/ai/finalize
```

Recording playback/download from Chatwoot UI:

```text
GET /api/v1/accounts/:account_id/telephony/calls/:call_ref/recording
```

`/event` and `/finalize` are compatibility adapter endpoints and must stay idempotent. Recording playback/download URLs must be signed short-lived URLs generated by Rails/Chatwoot; permanent `recording_url` is not durable state.

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
  },
  "recording": {
    "enabled": true,
    "source": "onelink_runtime",
    "storage_provider": "onelink_storage"
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

Required runtime/AI event types:

```text
session_started
call_started
stream_started
app_routing
app_answered
operator_ringing
operator_answered
transcript_delta
tool_started
tool_completed
tool_failed
transfer_requested
transfer_result
recording_ready
recording_unavailable
error
call_ended
session_completed
session_failed
```

Telecom/technical lifecycle events are sent by Fonoster/bridge. Recording lifecycle events (`recording_ready`, `recording_unavailable`, `error scope=recording`) are sent by the OneLink runtime that owns the recording writer/upload.

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
  "recording": {
    "recording_ref": "rec_123",
    "storage_key": "voice-recordings/2026/05/15/call_123/rec.wav",
    "duration_ms": 120000,
    "format": "wav",
    "channels": 2,
    "sample_rate": 8000,
    "channel_layout": "caller_left_remote_right"
  },
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
OneLink runtime emits error scope=recording
finalize must not wait for recording/upload
recording_ready may update metadata after terminal state
late recording_ready must not change terminal call status
```

## OneLink-Owned Recording Rules

Recording is a OneLink-owned media/storage artifact. Fonoster executes telecom and provides media topology; it is not the source of truth for recordings.

Runtime rules:

- recording happens inside the selected OneLink voice runtime
- write stereo WAV
- left channel = caller/local side
- right channel = remote side: AI/operator/app
- channels must be time-aligned
- write silence frames when one side is silent
- resample both directions to a common call rate
- writer must be append-only and non-blocking for realtime audio
- upload is asynchronous and must not block call completion
- recording/upload errors must not break the call flow

Rails/Chatwoot durable fields:

```text
recording_ref
storage_key
duration_ms
format
channels
channel_layout
sample_rate
encoding
mode
direction
metadata
```

Rails/Chatwoot owns:

```text
storage credentials
permissions
retention
audit/compliance
signed short-lived playback/download URLs
UI playback/download
```

Do not store a permanent `recording_url` as durable source of truth. Store `storage_key` and generate signed short-lived URLs at playback/download time.

Recording lifecycle events sent by OneLink runtime:

```text
recording_ready
recording_unavailable
error scope=recording
```

Recommended `recording_ready` payload:

```json
{
  "event_type": "recording_ready",
  "event_id": "evt_rec_01JZ...",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "call_ref": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "media_session_ref": "media-session-ref",
  "stream_ref": "stream-ref",
  "mode": "operator",
  "direction": "inbound",
  "recording_ref": "rec_123",
  "storage_key": "voice-recordings/2026/05/15/call_123/rec.wav",
  "duration_ms": 120000,
  "format": "wav",
  "channels": 2,
  "channel_layout": "caller_left_remote_right",
  "sample_rate": 8000,
  "encoding": "pcm_s16le",
  "source": "onelink-operator-voice"
}
```

Acceptance rules:

- for each enabled mode (`ai`, `operator`, `app`) and direction (`inbound`, `outbound`), OneLink runtime must see both audio directions
- if one mode cannot expose both audio directions, stereo recording for that mode is blocked until Fonoster media topology is fixed
- duplicate `recording_ready` must not create duplicate recordings/messages
- late `recording_ready` updates metadata only and must not change terminal call status

## Production Readiness Checklist

Code/contract readiness:

1. Rails exposes `/internal/voice/ai/event`.
2. Rails exposes `/internal/voice/ai/finalize`.
3. Rails exposes account-scoped recording playback/download endpoint.
4. `finalize` is idempotent.
5. Rails deduplicates events by `event_id` or compatible idempotency key.
6. OneLink runtime emits stable `event_seq`.
7. Transfer emits `transfer_requested` and `transfer_result`.
8. OneLink runtime emits `recording_ready`, `recording_unavailable`, and `error scope=recording`.
9. Recording can update metadata after finalize without changing terminal status.
10. No raw audio reaches Rails.
11. No permanent recording URL is stored as durable source of truth.

Deployment/media readiness:

1. Fonoster app refs point to selected OneLink runtimes, not local `test-voiceapp`.
2. Runtime gRPC ports are reachable from Fonoster and private from the public internet.
3. Running Fonoster image/media topology exposes both audio directions for each recordable mode.
4. Gemini keys exist only on the OneLink side.
5. Storage credentials exist only on the OneLink side.
6. Rails and OneLink runtimes use the same internal voice token.
7. Outbound calls use the selected OneLink runtime app ref.
8. Gemini outage fallback is tested.
9. OneLink runtime outage fallback is tested.
10. Operator no-answer path finalizes `operator_unavailable`.
11. Live smoke calls pass end to end for inbound/outbound and app/ai/operator.
12. Recording upload failure does not break a live call.

## Values To Fill For Fonoster Sync

These are deployment values, not source-code constants:

```text
onelink_ai_voice_private_host=<private host or IP reachable from Fonoster>
onelink_ai_voice_grpc_endpoint=<private host>:50061
onelink_ai_voice_health_endpoint=<private host>:8081, optional
fonoster_onelink_ai_app_ref=<Fonoster EXTERNAL app ref pointing to onelink-ai-voice>

onelink_operator_voice_grpc_endpoint=<private host>:<operator-runtime-port>
fonoster_onelink_operator_app_ref=<Fonoster EXTERNAL app ref pointing to onelink-operator-voice>

onelink_app_voice_grpc_endpoint=<private host>:<app-runtime-port>
fonoster_onelink_app_ref=<Fonoster EXTERNAL app ref pointing to onelink-app-voice>

operator_agent_aor=<production SIP AOR for fallback/transfer>
technical_fallback=<operator|reject|fallback_app_ref>
```

## E2E Recording Scenarios

Jointly test before production rollout:

1. `inbound -> AI` creates recording.
2. `inbound -> operator` creates recording.
3. `inbound -> app` creates recording.
4. `outbound -> AI/operator/app` creates recording.
5. `AI -> transfer to operator` either continues recording or closes it according to the agreed scenario.
6. `app/operator handoff failure` terminates call/session correctly and closes writer.
7. `recording upload failure` does not break the live call.
8. duplicate `recording_ready` does not create duplicates.
9. late `recording_ready` after terminal call status updates metadata only.

## Performance Requirements

- place OneLink runtime near the Fonoster media region
- avoid unnecessary transcoding
- keep recording writer non-blocking
- upload asynchronously
- pre-warm runtime workers where possible
- do not wait on Rails/storage in the realtime audio path
- measure latency, jitter, packet loss, writer lag, and handoff setup time

## Final Rule

```text
Fonoster = telecom execution, routing, media handoff, technical lifecycle.
OneLink runtime = media ownership for recording, writer, upload, recording lifecycle.
Rails/Chatwoot = CRM truth, metadata, permissions, signed URLs, UI, audit.
```

This is the native, reliable, scalable split for production voice agents and OneLink-owned call recording.
