# API Contracts

## Goal

This file describes suggested contracts for the first version of the bridge API.

## Public API For Chatwoot Or CRM Integrations

### Create Outbound Call

`POST /telephony/calls/outbound`

```json
{
  "from_number_ref": "d451bbe2-53d8-4458-bd0e-d811d85f57e0",
  "to": "+15551234567",
  "app_ref": "74fec1f6-48e8-436c-8147-9176a5da4fa4",
  "conversation_id": 123,
  "contact_id": 456
}
```

### Set Number Route

`POST /telephony/numbers/:numberRef/route`

```json
{
  "mode": "ai",
  "app_ref": "00000000-0000-0000-0000-000000000000"
}
```

or:

```json
{
  "mode": "operator",
  "agent_aor": "sip:1001@company.example"
}
```

### Enable Or Disable Agent

`POST /telephony/agents/:agentRef/enabled`

```json
{
  "enabled": true
}
```

### Get Webphone Token

`POST /telephony/webphone/token`

```json
{
  "chatwoot_user_id": 42
}
```

## Internal API Used By The Node Voice Runtime

### Inbound Route Decision

`POST /internal/voice/inbound/route`

```json
{
  "call_ref": "uuid",
  "ingress_number": "+18623964686",
  "caller_number": "+15557654321",
  "direction": "FROM_PSTN",
  "received_at": "2026-03-22T10:00:00Z",
  "metadata": {}
}
```

Response examples:

```json
{
  "action": "reject",
  "message": "We are currently closed."
}
```

```json
{
  "action": "operator",
  "agent_aor": "sip:1001@company.example"
}
```

```json
{
  "action": "ai",
  "app_ref": "00000000-0000-0000-0000-000000000000"
}
```

### Call-Time Event

`POST /internal/voice/inbound/event`

```json
{
  "call_ref": "uuid",
  "event": "answered",
  "conversation_id": 123,
  "payload": {}
}
```

## Evolution Rules

- Keep the external API stable for Chatwoot-facing consumers.
- Allow internal runtime contracts to evolve independently.
- Version endpoints once real clients start depending on them.
