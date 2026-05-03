# Onelink Bridge API Contract

Canonical bridge contract for regular telephony management and Fonoster inbound callbacks.
Last updated: 2026-05-03.

This document covers:

- Onelink Rails -> Fonoster telephony bridge command API.
- Fonoster bridge/runtime -> Onelink Rails inbound route and lifecycle events.

This document does not define Gemini Live internals. Use `ONELINK_FONOSTER_VOICE_CONTRACT.md` and `ONELINK_EXTERNAL_GEMINI_LIVE_VOICEAPP.md` for AI voice-agent behavior.

## Service Boundary

```text
Onelink Rails
  owns CRM call sessions, contacts, conversations, routing policy, UI/API state.

Fonoster bridge
  exposes product-level telephony commands to Onelink and normalizes provider/runtime events.

Fonoster core
  owns SIP/PSTN execution, numbers, trunks, applications, agents, calls.
```

Onelink should call the bridge for product-level telephony actions. Onelink should not embed raw Fonoster credentials in frontend code.

## Active Bridge Base URL

Deployment must configure this; do not hard-code `127.0.0.1` in Rails production.

```env
TELEPHONY_BRIDGE_BASE_URL=<bridge base URL reachable from Onelink Rails>
TELEPHONY_BRIDGE_SHARED_SECRET=<shared bridge secret>
```

The bridge may expose `GET /healthz` openly for uptime checks, but command endpoints must be protected by shared secret and network policy.

Accepted auth headers for bridge command endpoints:

```http
X-Bridge-Secret: <shared secret>
X-Bridge-Shared-Secret: <shared secret>
Authorization: Bearer <shared secret>
```

## Onelink -> Fonoster Bridge Commands

### Health

```http
GET /healthz
```

Used for readiness only.

### Resource Summary

```http
GET /telephony/resources/summary
```

Expected response includes numbers, applications, trunks, agents, and bridge capability data. Onelink uses this for readiness and admin UI.

### List Applications

```http
GET /telephony/applications
```

Use to discover app refs. The production AI app ref must point to the Onelink-hosted `onelink-ai-voice` EXTERNAL app, not local `test-voiceapp`.

### List Numbers

```http
GET /telephony/numbers
GET /telephony/numbers/:numberRef
```

Use for binding `Channel::Voice` to Fonoster numbers.

### List Trunks

```http
GET /telephony/trunks
```

Use for admin/resource readiness.

### List Agents

```http
GET /telephony/agents
```

Use to validate operator targets and agent availability where supported.

### Enable/Disable Agent

```http
POST /telephony/agents/:agentRef/enabled
```

Request:

```json
{
  "enabled": true
}
```

### Configure Number Route

```http
POST /telephony/numbers/:numberRef/route
```

Request:

```json
{
  "mode": "operator",
  "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz",
  "fallback_mode": "reject",
  "fallback_message": "We are unable to connect your call right now."
}
```

AI route request:

```json
{
  "mode": "ai",
  "ai_mode": "onelink_managed",
  "ai_app_ref": "<onelink_ai_app_ref>",
  "fallback_mode": "operator",
  "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz"
}
```

Rules:

- `mode=ai` must use a real AI app ref.
- The production AI app ref must point to `onelink-ai-voice`.
- Do not route the number back to the same runtime/router app as its target.
- Historical smoke-test UUIDs must not be treated as production constants.

### Toggle AI

```http
POST /telephony/ai/toggle
```

Request:

```json
{
  "number_ref": "<fonoster-number-ref>",
  "enabled": true,
  "ai_mode": "onelink_managed",
  "ai_app_ref": "<onelink_ai_app_ref>",
  "fallback_mode": "operator",
  "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz"
}
```

### Create Outbound Call

```http
POST /telephony/calls/outbound
```

Operator outbound request:

```json
{
  "from": "+18623964686",
  "to": "+77066318623",
  "agent_aor": "sip:1001@operator.cloud.vconsult.kz",
  "metadata": {
    "onelink_account_id": 1,
    "conversation_id": 12345,
    "contact_id": 456
  }
}
```

AI outbound request:

```json
{
  "from": "+18623964686",
  "to": "+77066318623",
  "app_ref": "<onelink_ai_app_ref>",
  "ai_mode": "onelink_managed",
  "metadata": {
    "onelink_account_id": 1,
    "conversation_id": 12345,
    "contact_id": 456
  }
}
```

Response:

```json
{
  "ref": "fonoster-call-ref",
  "status": "created"
}
```

Onelink must store `ref` as the provider call reference and reconcile status through later events or call polling.

### List Calls

```http
GET /telephony/calls
GET /telephony/calls/:callRef
```

Use for diagnostics and reconciliation. Events remain the primary source for CRM state transitions.

## Fonoster Bridge -> Onelink Callbacks

These endpoints are served by Rails and called by the Fonoster bridge/runtime.

```text
POST /internal/voice/inbound/route
POST /internal/voice/inbound/event
POST /telephony/internal/events
```

Required callback headers:

```http
Content-Type: application/json
X-Account-Id: <onelink account id>
X-Request-Id: <uuid>
Authorization: Bearer <shared token>
```

Compatibility auth accepted by Rails:

```http
X-Bridge-Secret: <token>
X-Telephony-Secret: <token>
Authorization: Bearer <token>
```

## Inbound Route Decision

Endpoint:

```http
POST /internal/voice/inbound/route
```

Request should include both canonical and compatibility identifiers when available:

```json
{
  "call_ref": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "callRef": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "media_session_ref": "optional-media-session-ref",
  "mediaSessionRef": "optional-media-session-ref",
  "ingress_number": "+18623964686",
  "ingressNumber": "+18623964686",
  "caller_number": "+77066318623",
  "callerNumber": "+77066318623",
  "direction": "FROM_PSTN",
  "app_ref": "runtime-router-app-ref",
  "appRef": "runtime-router-app-ref",
  "received_at": "2026-05-03T12:00:00.000Z",
  "metadata": {}
}
```

Onelink response actions:

```text
operator
app
ai
reject
```

Operator response:

```json
{
  "action": "operator",
  "agent_aor": "sip:1001@operator.cloud.vconsult.kz",
  "reason": "operator_route",
  "timeout": 30
}
```

AI response:

```json
{
  "action": "ai",
  "ai_mode": "onelink_managed",
  "app_ref": "<onelink_ai_app_ref>",
  "reason": "onelink_ai_route",
  "timeout": 60,
  "fallback": {
    "on_ai_unavailable": "operator",
    "operator_agent_aor": "sip:1001@operator.cloud.vconsult.kz"
  }
}
```

Reject response:

```json
{
  "action": "reject",
  "message": "We are unable to connect your call right now.",
  "reason": "number_not_bound"
}
```

Rules:

- Return HTTP `200` for business rejection with `action=reject`.
- Non-2xx means technical failure and can trigger bridge retry/fallback.
- `action=operator` requires executable `agent_aor`.
- `action=app` and `action=ai` require executable `app_ref`.
- Do not return the same runtime/router app ref as the target for the same inbound call.
- Prefer snake_case in Onelink responses; camelCase aliases are compatibility only.

## Inbound Event Sink

Endpoints:

```http
POST /internal/voice/inbound/event
POST /telephony/internal/events
```

Payload example:

```json
{
  "event_type": "session_started",
  "eventType": "session_started",
  "call_ref": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "callRef": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "media_session_ref": "optional-media-session-ref",
  "ingress_number": "+18623964686",
  "caller_number": "+77066318623",
  "app_ref": "runtime-router-app-ref",
  "direction": "FROM_PSTN",
  "metadata": {}
}
```

Event types bridge should send:

```text
session_started
route_decision
decision_received
ringing
answered
dial_status
session_completed
session_failed
recording_ready
unknown future event types without rejection
```

Normalized dial statuses:

```text
answered
no-answer
busy
failed
```

Do not send raw provider uppercase statuses directly to Onelink without normalized status:

```text
ANSWER
NOANSWER
BUSY
FAILED
CANCEL
```

Expected response:

```json
{
  "status": "ok",
  "call_ref": "8411db93-f9fb-4e29-9209-6a2fddf8df95",
  "conversation_id": "12345"
}
```

## Event Handling Rules

Onelink must:

- treat delivery as at least once
- deduplicate by `X-Idempotency-Key`, `event_key`, or compatible payload key
- create/find one call session per `account_id + provider + call_ref`
- store raw event payloads for audit/debugging
- return fast `2xx` for duplicates
- process heavy CRM side effects asynchronously
- not let late non-terminal events reopen terminal calls
- preserve unknown fields and future event types

## CRM Call State Rules

Canonical CRM-facing statuses:

```text
queued
ringing
in-progress
completed
no-answer
failed
```

Terminal statuses:

```text
completed
no-answer
failed
```

Target mapping:

```text
session_started -> ringing
decision_received -> ringing
ringing -> ringing
answered -> in-progress
dial_status answered -> in-progress
dial_status no-answer -> no-answer
dial_status busy -> no-answer
dial_status failed -> failed
session_completed -> completed
session_failed -> failed
recording_ready -> no status downgrade
```

Important UI rule: CRM accept/route action is not proof of answered media. Move to `in-progress` only after Fonoster/SIP/runtime answer confirmation.

## Required Business Cases

Before production traffic:

1. Bound inbound number routes to operator/app/AI, not `number_not_bound`.
2. Unknown inbound number returns `200 action=reject reason=number_not_bound`.
3. Known caller attaches to existing contact/conversation.
4. Unknown caller creates/attaches a contact or temporary lead.
5. Inbound before answer is visible as `ringing`.
6. Operator answer moves to `in-progress` only after runtime/SIP answer.
7. Caller hangup before answer becomes `no-answer` or `failed` according to available provider reason.
8. Hangup after answer becomes `completed` with duration when available.
9. AI enabled returns `action=ai` with production `onelink_ai_app_ref`.
10. AI disabled returns `operator`, `app`, or `reject` according to routing policy.
11. Outbound call creates local call session immediately after bridge `ref` is returned.
12. Outbound no-answer/busy/failed remain distinct from successful completed calls where the model supports it.
13. Duplicate events do not create duplicate call sessions.
14. Late non-terminal events do not overwrite terminal status.
15. Recording can update the call after terminal status.

## Production Checklist

Onelink:

1. `Channel::Voice` exists with `provider=fonoster`.
2. `telephony_number_binding` exists for each active number.
3. `telephony_routing_policy` has executable mode and targets.
4. Bridge base URL and shared secret are configured.
5. Readiness endpoint reports bridge reachable and resources bound.
6. Inbound route endpoint returns executable decisions.
7. Inbound event endpoint is idempotent.
8. Outbound call flow stores bridge `ref`.

Fonoster:

1. DID route reaches runtime/router app.
2. Operator AOR exists and is executable before using `action=operator`.
3. Onelink AI app ref points to `onelink-ai-voice` before using production `action=ai`.
4. Bridge command endpoints are protected.
5. Bridge callback auth to Rails is configured.
6. Event normalization is enabled.

## Final Rule

Use this bridge contract for telephony commands and route/event callbacks.
Use `ONELINK_FONOSTER_VOICE_CONTRACT.md` for the AI voice-agent contract.
