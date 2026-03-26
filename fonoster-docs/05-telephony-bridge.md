# Telephony Bridge

## Purpose

The bridge is the business-aware layer between Chatwoot and Fonoster.

Current implementation path:

- [`/root/fonoster-docker/telephony-bridge`](/root/fonoster-docker/telephony-bridge)

It should:

- expose a simple telephony API to Chatwoot
- call Fonoster SDK/API
- keep product-specific routing rules out of Fonoster
- persist telephony-related mapping state
- normalize call events for Chatwoot

## Recommended Responsibilities

### Command Layer

Handle actions such as:

- create outbound call
- list the resources Chatwoot needs for telephony UX
- expose a concise capabilities view
- set number route
- enable or disable AI mode
- enable or disable operator availability
- fetch call history
- request browser-phone token

### Routing Layer

For inbound calls decide:

- reject
- send to AI
- send to operator
- send to voicemail
- ask caller for input and route again

### Synchronization Layer

Maintain mapping between:

- Chatwoot users and Fonoster agents
- Chatwoot inboxes and Fonoster numbers
- Chatwoot channels and Fonoster trunks or apps

### Event Layer

Process:

- call started / ended events
- AI conversation events
- tool execution side effects
- transcript and summary persistence

## Recommended Internal Modules

- `fonoster_client`
- `chatwoot_client`
- `calls_service`
- `routing_service`
- `agents_service`
- `numbers_service`
- `ai_mode_service`
- `events_service`
- `webphone_service`

## Recommended Public API Surface

- `POST /telephony/calls/outbound`
- `GET /telephony/capabilities`
- `GET /telephony/resources/summary`
- `GET /telephony/applications`
- `GET /telephony/numbers`
- `GET /telephony/numbers/:numberRef`
- `GET /telephony/trunks`
- `GET /telephony/agents`
- `GET /telephony/calls`
- `GET /telephony/calls/:callRef`
- `POST /telephony/numbers/:numberRef/route`
- `POST /telephony/agents/:agentRef/enabled`
- `POST /telephony/ai/toggle`
- `POST /telephony/webphone/token`

## Recommended Internal Endpoints For Voice Runtime

- `POST /internal/voice/inbound/route`
- `POST /internal/voice/inbound/event`
- `POST /internal/voice/ai/tool/:toolName`

Current live local bind:

- `127.0.0.1:38081 -> telephony-bridge:3100`

Current implementation status:

- `capabilities`, `resources/summary`, `applications`, `numbers`, `trunks`, `agents`, `calls`, `webphone/token`, and internal route/event endpoints are working
- `numbers/:numberRef/route` and `ai/toggle` are working through a direct `routr.numbers` DB fallback
- the bridge uses this fallback specifically because the public Fonoster `UpdateNumber` path is buggy on this instance
- `voice-runtime` already consumes the bridge through `/internal/voice/inbound/route` and `/internal/voice/inbound/event`

## Data The Bridge Should Store

- mapping table between Chatwoot inboxes and Fonoster numbers
- mapping table between Chatwoot users and Fonoster agents
- active routing policy per number
- AI mode policy per inbox or number
- external call reference mapping
- recordings/transcripts metadata

## What The Bridge Should Not Do

The bridge should not replace Fonoster.

It should not implement:

- SIP signaling
- RTP/media handling
- low-level PBX behavior
- direct Asterisk/Routr logic

It also should not blindly duplicate every native Fonoster CRUD route unless Chatwoot has a real product need for that wrapper.
