# Onelink Fonoster Voice Contract

This is the production integration contract between Onelink and the Fonoster
execution layer for voice calls and Gemini Live voice agents.

This file is intentionally stricter than an architecture note. It defines the
boundary, required identifiers, event schemas, retry/idempotency rules, transfer
behavior, fallback behavior, and open questions that must be closed before live
production traffic.

## Non-Negotiable Boundary

Onelink is the source of truth.

Fonoster is the reliable call execution layer.

```text
Onelink Rails
  owns CRM state, customer context, prompt policy, tools, routing policy,
  transcript storage, final call status, summaries, business fallback rules,
  and the decision to transfer to an operator.

Onelink AI Voice Service
  owns the realtime voice-agent runtime next to Onelink: Fonoster VoiceServer,
  Gemini Live websocket, audio pacing, barge-in, Gemini tool calls, transcript
  batching, and low-level call actions after Onelink authorizes them.

Fonoster
  owns PSTN/SIP, inbound call delivery, outbound createCall execution,
  voice.stream, dial/transfer execution, hangup, recording, and technical call
  events.
```

Rails must not receive live audio frames. Audio flows only between Fonoster and
the Onelink AI Voice Service. Rails receives JSON only.

## What Fonoster Must Not Own

Fonoster must not own or persist:

- Gemini API keys
- AI prompts
- customer context
- CRM tools
- business routing policy
- operator selection policy
- transcript canonical storage
- final business call status
- summaries
- tenant-specific AI behavior

Fonoster may hold only technical configuration needed to execute the call, such
as app refs, SIP domains, trunk config, and safe technical fallback targets.

## Required Services

```text
Fonoster server
  telephony-bridge
  voice-runtime
  apiserver
  asterisk
  routr
  rtpengine

Onelink server
  Rails CRM
  onelink-ai-voice
```

`onelink-ai-voice` is the production successor to the current
`test-voiceapp` reference implementation.

## Information To Give Fonoster Team

Fonoster team needs only the information required to execute calls and deliver
technical events.

Give Fonoster team:

- Onelink AI Voice Service endpoint reachable from the Fonoster server:
  `<private-host>:50061`
- optional health/metrics endpoint if exposed, for example
  `<private-host>:8081`
- Fonoster application ref that points to this endpoint, or permission to
  update/create that application ref
- network access requirements: private DNS/VPN/allowlist, TCP `50061`, optional
  TCP `8081`
- required routing behavior: use Onelink route decisions and target app refs
- technical fallback policy only
- call event contract: ids, event names, retry rules, final statuses, transfer
  results, and error reason codes

Do not give Fonoster team:

- Rails internal auth secret
- Gemini keys
- CRM database access
- internal Rails controllers/routes
- prompt templates
- CRM tool implementation
- customer context rules
- operator selection/business policy beyond the route/transfer decision payload

If the Fonoster team operates part of the deployment on Onelink's behalf, secrets
may be injected by Onelink operations, but they are not part of the Fonoster
application contract.

## Onelink-Internal Inputs

These are required for Onelink's own implementation and verification, but not
for the external Fonoster team:

- current Rails routes/controllers for `/context`, `/transcript`,
  `/tools/:name`, and `/control`
- the internal auth header/secret between `onelink-ai-voice` and Rails
- the Gemini API key
- Rails data model for calls, conversations, transcripts, raw events, and
  finalization
- business fallback policy per account/channel
- operator availability and selection logic

## Transport And Auth

### Fonoster Voice gRPC To Onelink AI Voice Service

The Fonoster application endpoint must point to the Onelink AI Voice Service:

```text
<onelink-private-host>:50061
```

This endpoint must be private. Use WireGuard, Tailscale, private VPC, or a
firewall that allows only the Fonoster server.

Do not expose the voice gRPC endpoint publicly without TLS/mTLS.

### Fonoster Bridge To Onelink Rails

Inbound route and event callbacks use internal HTTP:

```text
POST /internal/voice/inbound/route
POST /internal/voice/inbound/event
```

Required headers:

```http
Content-Type: application/json
X-Account-Id: <onelink account id>
X-Request-Id: <uuid>
Authorization: Bearer <shared internal token>
```

For event delivery, also send:

```http
X-Event-Id: <event_id>
X-Idempotency-Key: <event_id>
X-Event-Attempt: <attempt number, starting at 1>
```

These Rails credentials are Onelink-controlled deployment configuration. They
should not be handed to the Fonoster team as product integration inputs.

### Onelink AI Voice Service To Rails

Current Onelink AI endpoints may remain:

```text
POST /internal/voice/ai/context
POST /internal/voice/ai/transcript
POST /internal/voice/ai/tools/:name
POST /internal/voice/ai/control
```

Rails exposes compatible adapter endpoints for external integrators and future
Fonoster runtime work:

```text
POST /internal/voice/ai/event
POST /internal/voice/ai/finalize
```

Do not remove the current endpoints. The adapter endpoints should call the same
internal Rails services used by the existing implementation.

Required headers:

```http
Content-Type: application/json
X-Request-Id: <uuid>
Authorization: Bearer <onelink internal token>
```

For events and finalize:

```http
X-Event-Id: <event_id>
X-Idempotency-Key: <event_id or finalize key>
X-Event-Attempt: <attempt number, starting at 1>
```

## Canonical Identifiers

Every cross-service request must use stable identifiers.

```text
call_id
  Onelink canonical call row id. Created by Onelink.

provider_call_id
  Fonoster call reference. In current code this maps to call_ref / callRef.
  Stable across the technical call lifecycle.

media_session_ref
  Fonoster media session / channel reference. Useful for debugging and active
  voice stream correlation.

ai_session_id
  Onelink AI Voice Service session id. One active realtime Gemini session per
  call. May equal media_session_ref, but should be treated as its own id.

conversation_id
  Onelink conversation linked to the call.

event_id
  Unique id for one event. Retries must reuse the same event_id.

event_seq
  Monotonic integer inside one provider_call_id or ai_session_id. Starts at 1.
  Used for ordering and duplicate detection.

request_id
  Trace id for one HTTP delivery attempt.

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

If `call_id` is not known yet, send `provider_call_id` and `ai_session_id`.
Rails must attach the event once `call_id` is created.

## Idempotency And Ordering

Delivery is at least once.

The sender must:

- retry transient failures
- reuse the same `event_id` on retry
- reuse the same `X-Idempotency-Key` on retry
- increment `attempt`
- never generate a new event id for the same event

Rails must deduplicate by:

```text
(provider_call_id, event_id)
```

or, for AI runtime events:

```text
(ai_session_id, event_seq)
```

The recommended primary dedupe key is:

```text
event_id
```

with `provider_call_id` as a safety scope.

Events may arrive out of order. Rails must accept out-of-order events and apply
state transitions safely. `finalize` is terminal for business state, but late
non-conflicting events such as `recording_ready` may still update the call row.

Duplicate response:

```json
{
  "status": "duplicate",
  "event_id": "evt_01JZ...",
  "call_id": "call_123"
}
```

## Retry Rules

Retry on:

- network timeout
- connection reset
- HTTP 408
- HTTP 409 when the response explicitly says retryable
- HTTP 425
- HTTP 429
- HTTP 500, 502, 503, 504

Do not retry on normal validation errors:

- HTTP 400
- HTTP 401
- HTTP 403
- HTTP 404
- HTTP 422

Recommended retry schedule for events:

```text
1s, 5s, 15s, 60s, 5m, 15m
```

Use jitter. Stop retrying after the configured event retention window, but keep
an operational dead-letter log.

Route decision calls are different:

- target p95: under 300 ms
- hard timeout: 1500 ms
- if route decision fails, only technical fallback may run

Event/finalize calls:

- target p95: under 300 ms
- hard timeout: 2000 ms
- retry is allowed

## Inbound Route Decision

Fonoster asks Onelink what to do with the inbound call.

```http
POST /internal/voice/inbound/route
```

### Request

```json
{
  "event_id": "evt_route_01JZ...",
  "event_type": "inbound_route_requested",
  "event_seq": 1,
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "call_ref": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "media_session_ref": "asterisk-channel-or-media-session",
  "from": "+77066318623",
  "to": "+18623964686",
  "direction": "inbound",
  "ingress_number": "+18623964686",
  "app_ref": "96fc259c-6bcd-4cbf-bb7d-d2c51f248934",
  "started_at": "2026-05-03T12:00:00.000Z",
  "received_at": "2026-05-03T12:00:00.100Z",
  "attempt": 1,
  "metadata": {}
}
```

### Response: AI Route

```json
{
  "action": "ai",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "app_ref": "onelink_ai_voice_app_ref",
  "ai_session_mode": "onelink_managed",
  "reason": "ai_enabled",
  "timeout": 60,
  "fallback": {
    "on_ai_unavailable": "operator",
    "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz",
    "fallback_app_ref": "fallback_app_ref"
  }
}
```

### Response: Operator Route

```json
{
  "action": "operator",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "agent_aor": "sip:1001@operator.cloud.vconsult.kz",
  "reason": "non_pending_conversation_operator_route",
  "timeout": 30
}
```

### Response: Reject

Business rejection must return HTTP 200 with `action=reject`.

```json
{
  "action": "reject",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "message": "We are currently closed.",
  "reason": "business_hours_closed"
}
```

Non-2xx means technical failure, not business rejection.

## Onelink AI Context

The Onelink AI Voice Service asks Rails for AI context.

```http
POST /internal/voice/ai/context
```

### Request

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

### Response

```json
{
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "contact_id": "contact_123",
  "language": "ru-RU",
  "model": "gemini-3.1-flash-live-preview",
  "voice": "Sulafat",
  "system_prompt": "You are the Onelink voice assistant. Keep answers short.",
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

Rails owns this response. Fonoster must not invent prompt, tools, or CRM
context locally.

## Event Adapter Endpoint

Rails exposes this compatibility endpoint:

```http
POST /internal/voice/ai/event
```

It accepts lifecycle, media, tool, transfer, recording, and error events from
the Onelink AI Voice Service or a future Fonoster runtime.

It should adapt internally to the current Rails control/event processing.

### Common Event Shape

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

### Response

```json
{
  "status": "ok",
  "event_id": "evt_01JZ...",
  "call_id": "call_123",
  "conversation_id": "conv_123"
}
```

## Required Event Types

### call_started

```json
{
  "event_id": "evt_call_started_01JZ...",
  "event_seq": 1,
  "event_type": "call_started",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "media_session_ref": "asterisk-channel-or-media-session",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "from": "+77066318623",
  "to": "+18623964686",
  "direction": "inbound",
  "started_at": "2026-05-03T12:00:00.000Z",
  "occurred_at": "2026-05-03T12:00:00.000Z",
  "attempt": 1,
  "payload": {
    "app_ref": "onelink_ai_voice_app_ref",
    "route_action": "ai"
  }
}
```

### stream_started

```json
{
  "event_id": "evt_stream_started_01JZ...",
  "event_seq": 2,
  "event_type": "stream_started",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "media_session_ref": "asterisk-channel-or-media-session",
  "ai_session_id": "ai_sess_01JZ...",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "occurred_at": "2026-05-03T12:00:01.000Z",
  "attempt": 1,
  "payload": {
    "stream_ref": "stream_uuid",
    "direction": "BOTH",
    "input_rate": 16000,
    "output_rate": 8000,
    "gemini_model": "gemini-3.1-flash-live-preview"
  }
}
```

### transcript_delta

Use this for partial or batched transcript updates if the existing
`/transcript` endpoint is not used.

```json
{
  "event_id": "evt_transcript_01JZ...",
  "event_seq": 8,
  "event_type": "transcript_delta",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "ai_session_id": "ai_sess_01JZ...",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "occurred_at": "2026-05-03T12:00:15.000Z",
  "attempt": 1,
  "payload": {
    "speaker": "caller",
    "text": "I want to talk to an operator.",
    "is_final": true,
    "provider": "gemini-live"
  }
}
```

### transfer_requested

This event records the intent to transfer. It does not prove the operator
answered.

```json
{
  "event_id": "evt_transfer_requested_01JZ...",
  "event_seq": 11,
  "event_type": "transfer_requested",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "ai_session_id": "ai_sess_01JZ...",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "occurred_at": "2026-05-03T12:01:10.000Z",
  "attempt": 1,
  "payload": {
    "requested_by": "ai_tool",
    "reason": "caller_requested_operator",
    "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz"
  }
}
```

### transfer_result

Allowed results:

```text
answered
no_answer
busy
failed
cancelled
```

```json
{
  "event_id": "evt_transfer_result_01JZ...",
  "event_seq": 12,
  "event_type": "transfer_result",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "ai_session_id": "ai_sess_01JZ...",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "occurred_at": "2026-05-03T12:01:20.000Z",
  "attempt": 1,
  "payload": {
    "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz",
    "result": "answered",
    "dial_started_at": "2026-05-03T12:01:10.000Z",
    "answered_at": "2026-05-03T12:01:18.000Z",
    "ended_at": null,
    "duration_ms": 8000,
    "bridge_id": "optional-bridge-id",
    "error_code": null,
    "error_message": null
  }
}
```

### call_ended

Use this technical event when the call leg ends. It does not replace
`finalize`.

```json
{
  "event_id": "evt_call_ended_01JZ...",
  "event_seq": 20,
  "event_type": "call_ended",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "ai_session_id": "ai_sess_01JZ...",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "occurred_at": "2026-05-03T12:02:00.000Z",
  "attempt": 1,
  "payload": {
    "ended_by": "caller",
    "reason": "caller_hung_up",
    "duration_ms": 120000
  }
}
```

### recording_ready

Recording may arrive after `finalize`.

```json
{
  "event_id": "evt_recording_ready_01JZ...",
  "event_seq": 21,
  "event_type": "recording_ready",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "occurred_at": "2026-05-03T12:02:10.000Z",
  "attempt": 1,
  "payload": {
    "recording_url": "https://recordings.example/call_123.wav",
    "recording_ref": "rec_123",
    "format": "wav",
    "duration_ms": 120000
  }
}
```

### error

```json
{
  "event_id": "evt_error_01JZ...",
  "event_seq": 15,
  "event_type": "error",
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "ai_session_id": "ai_sess_01JZ...",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "occurred_at": "2026-05-03T12:01:30.000Z",
  "attempt": 1,
  "payload": {
    "scope": "gemini_live",
    "error_code": "gemini_unavailable",
    "error_message": "Gemini Live websocket closed before setup",
    "retryable": false
  }
}
```

## Finalize Endpoint

Rails exposes this endpoint:

```http
POST /internal/voice/ai/finalize
```

`finalize` is the canonical terminal business event for the AI voice session.

It must be idempotent.

### Allowed Final Statuses

```text
completed
transferred
failed
caller_hung_up
operator_unavailable
```

Optional extended statuses, if Onelink wants them:

```text
rejected
cancelled
timeout
```

### Request

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

### Response

```json
{
  "status": "ok",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "already_finalized": false
}
```

Duplicate finalize with the same terminal payload must return 2xx:

```json
{
  "status": "ok",
  "call_id": "call_123",
  "conversation_id": "conv_123",
  "already_finalized": true
}
```

If a duplicate finalize conflicts with the stored terminal state, Rails should
keep the first final state, store an operational conflict event, and return 2xx
with the stored state. Do not break the sender retry loop with a terminal 5xx.

## Tool Boundary

Fonoster must not implement CRM tools.

Allowed low-level call actions:

```text
transfer
end_call
hold
playback, only if Onelink explicitly enables it
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

Tool call flow:

```text
Gemini tool_call
-> onelink-ai-voice
-> Rails /internal/voice/ai/tools/:name
-> Rails returns business decision
-> onelink-ai-voice executes only allowed low-level call action
-> onelink-ai-voice returns toolResponse to Gemini
```

### Transfer Tool Result From Rails

```json
{
  "ok": true,
  "action": "transfer",
  "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz",
  "reason": "caller_requested_operator",
  "timeout": 30
}
```

### End Call Tool Result From Rails

```json
{
  "ok": true,
  "action": "end_call",
  "reason": "caller_finished"
}
```

If Rails returns a CRM-only result, the voice service must not invent a transfer.

## Transfer Contract

When Onelink authorizes transfer, the voice service or Fonoster execution layer
must:

1. Dial `operator_agent_aor`.
2. Preserve caller id where supported by the trunk/provider.
3. Emit `transfer_requested`.
4. Emit `transfer_result`.
5. Return one of:

```text
answered
no_answer
busy
failed
cancelled
```

6. Include bridge timestamps:

```json
{
  "dial_started_at": "2026-05-03T12:01:10.000Z",
  "ringing_at": "2026-05-03T12:01:11.000Z",
  "answered_at": "2026-05-03T12:01:18.000Z",
  "ended_at": null,
  "duration_ms": 8000
}
```

7. Do not lose recording or final call state.

If the operator does not answer, final status should be:

```text
operator_unavailable
```

unless Onelink context explicitly says to continue AI or use another fallback.

## Fallback Rules

Fallback policy is owned by Onelink. Fonoster may only perform technical
fallback when Onelink cannot be reached or the selected target is unavailable.

### Gemini Unavailable

Expected behavior:

1. Onelink AI Voice Service emits `error` with `scope=gemini_live`.
2. It applies Rails-provided `fallback_policy`.
3. If policy is `operator`, it asks/uses Onelink-approved operator target and
   attempts transfer.
4. If no fallback is available, it finalizes `failed`.

### Onelink AI Voice Service Unavailable

Expected behavior:

1. Fonoster fails to connect the selected EXTERNAL app endpoint.
2. Fonoster uses only technical fallback from route response or cached policy.
3. Fonoster emits an error event to Onelink when possible.
4. If no fallback exists, Fonoster rejects or ends the call safely.

### Onelink Rails Context API Slow Or Down

Expected behavior:

1. Onelink AI Voice Service times out quickly.
2. It uses the configured fallback policy.
3. It emits `error` and eventually `finalize`.
4. It never blocks the audio callback waiting on Rails.

### Operator Unavailable

Expected behavior:

1. Emit `transfer_result` with `no_answer`, `busy`, or `failed`.
2. Finalize as `operator_unavailable`, unless Onelink explicitly configured AI
   continuation or a second operator/fallback target.

### Stream Broken

Realtime media stream cannot be safely retried inside the same call as if
nothing happened.

Expected behavior:

1. Emit `error` with `scope=voice_stream`.
2. Stop Gemini audio loop.
3. Apply Onelink fallback policy.
4. If no fallback exists, finalize `failed` with a clear `error_code`.

## Required Fonoster Behavior

Fonoster team must:

1. Treat Onelink routing decisions as authoritative.
2. Connect calls to the Onelink-selected app ref or operator target.
3. Avoid local business rules except technical fallback.
4. Emit stable identifiers in every event:

```json
{
  "provider_call_id": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "from": "+77066318623",
  "to": "+18623964686",
  "direction": "inbound",
  "started_at": "2026-05-03T12:00:00.000Z",
  "event_id": "evt_01JZ...",
  "event_type": "call_started",
  "event_seq": 1,
  "attempt": 1
}
```

5. Deliver webhooks at least once.
6. Retry transient failures with the same `event_id`.
7. Preserve recording and final call state across transfer.
8. Keep audio out of Rails.

Fonoster team must not:

- store Gemini keys
- own prompt logic
- implement CRM tools
- select operators without Onelink policy
- decide AI vs operator except technical fallback
- send raw audio to Rails

## Recording Rules

Recording is a technical artifact from Fonoster.

Rules:

- recording may be delivered after finalize
- `recording_ready` must update the existing call row
- missing recording must not block finalize
- if recording failed, emit `error` with `scope=recording`

Recommended recording payload:

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

## State Machine

Recommended Onelink canonical state transitions:

```text
created
-> ringing
-> in_progress
-> transferred
-> completed
```

Failure paths:

```text
created -> rejected
created -> failed
in_progress -> caller_hung_up
in_progress -> operator_unavailable
in_progress -> failed
```

`recording_ready` may arrive after any terminal state.

## Production Readiness Checklist

Before enabling production traffic:

1. Fonoster app endpoint points to Onelink AI Voice Service.
2. Voice gRPC endpoint is private.
3. Gemini keys exist only on the Onelink server.
4. Bidirectional Fonoster stream is verified with real audio both ways.
5. Rails implements `/internal/voice/ai/event`.
6. Rails implements `/internal/voice/ai/finalize`.
7. `finalize` is idempotent.
8. Rails deduplicates events by `event_id`.
9. AI service includes `event_seq`.
10. Route decisions return `call_id` or create it deterministically.
11. Transfer emits requested and result events.
12. Recording can update after finalize.
13. Gemini outage fallback is tested.
14. Onelink AI Voice Service outage fallback is tested.
15. Operator no-answer path finalizes `operator_unavailable`.
16. Outbound AI call uses the Onelink AI app ref.
17. No raw audio reaches Rails.

## Questions For Onelink

These must be answered by the Onelink side before the contract is considered
closed.

1. What is the canonical `call_id` format, and is it created during inbound
   route decision or AI context fetch?
2. Does Rails already have a call-session table that can store
   `provider_call_id`, `media_session_ref`, `ai_session_id`, and `event_seq`?
3. Which endpoint currently owns lifecycle events: `/control`, an events
   service, or another controller?
4. Should `/internal/voice/ai/event` write to the same table as current bridge
   lifecycle events, or to a separate AI voice events table?
5. What exact auth header should the Onelink AI Voice Service use for Rails:
   `Authorization: Bearer`, `X-Bridge-Secret`, or a new internal header?
6. Should `finalize` create the summary synchronously, or should it store the
   final payload and enqueue summary generation?
7. What final statuses does the UI expect today?
8. Can `recording_url` be updated after terminal state in the current UI/model?
9. What transcript format is canonical: append-only utterances, full final text,
   or both?
10. Who owns operator availability: Rails only, or Rails plus Fonoster SIP
    registration state?
11. When transfer fails, should AI continue, try a second operator, or finalize
    `operator_unavailable`?
12. What is the tenant/account fallback policy when Gemini is unavailable?
13. What is the max allowed AI call duration per account?
14. Are there compliance requirements for recording consent, retention,
    redaction, or PII masking?
15. Should outbound AI calls use the same `onelink_ai_app_ref` as inbound AI
    calls?
16. Should event payloads be stored raw for audit/debugging?
17. What is the acceptable event replay retention window?
18. Should the AI service be allowed to call `voice.dial` directly after Rails
    returns a transfer action, or must it go through another Onelink control
    approval step?

## Final Contract Summary

The correct production model is:

```text
Fonoster executes the call.
Onelink AI Voice Service runs Gemini Live.
Onelink Rails owns business truth.
```

The system is production-ready only when events and finalize are idempotent,
retries are at least once with stable event ids, transfer has explicit result
semantics, fallback policy is owned by Onelink, and no realtime audio passes
through Rails.
