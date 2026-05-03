# Onelink AI Voice Agent Migration Plan

Archived document.
Last updated: 2026-05-03.

This file is no longer the active source of truth for Fonoster synchronization.
The migration decision is closed: Gemini Live runs in `onelink-ai-voice`, a separate Node service next to Onelink Rails, not inside Rails and not as a production app on the Fonoster server.

Use the active documents instead:

- `ONELINK_CRM_GEMINI_SYNC_HANDOFF.md` - exact handoff checklist for syncing
  with the Onelink CRM/Gemini team.
- `ONELINK_FONOSTER_VOICE_CONTRACT.md` - canonical production behavior and integration contract.
- `ONELINK_EXTERNAL_GEMINI_LIVE_VOICEAPP.md` - deployment/runbook for the Onelink-hosted Gemini Live VoiceApp.
- `ONELINK_BRIDGE_API_CONTRACT.md` - regular telephony bridge API and inbound route/event contract.

## Current Architecture

```text
Fonoster = PSTN/SIP, app refs, call execution, media bridge
onelink-ai-voice = realtime Gemini Live audio loop
Rails Onelink = CRM truth, context, prompts, tools, routing, transcript, finalize
```

## Current Code Location

```text
services/onelink-ai-voice/
```

Rails internal endpoints:

```text
POST /internal/voice/ai/context
POST /internal/voice/ai/transcript
POST /internal/voice/ai/tools/:name
POST /internal/voice/ai/control
POST /internal/voice/ai/event
POST /internal/voice/ai/finalize
```

## Closed Decisions

- Do not put realtime Gemini Live audio inside Rails.
- Do not keep Gemini keys on the Fonoster server.
- Do not use local `test-voiceapp` as the production AI target.
- Do not give Fonoster prompt/customer/tool ownership.
- Use one Gemini Live websocket per active call.
- Use Rails only for JSON control plane and durable business state.

## Remaining Work Is Deployment, Not Migration Planning

Production readiness now depends on:

1. Private network reachability from Fonoster to `onelink-ai-voice:50061`.
2. Fonoster `EXTERNAL` app ref pointing to `onelink-ai-voice`.
3. Matching internal voice secret on Rails and `onelink-ai-voice`.
4. Gemini key present only on the Onelink side.
5. Live inbound and outbound smoke calls.

The concrete cross-team handoff is documented in
`ONELINK_CRM_GEMINI_SYNC_HANDOFF.md`.
