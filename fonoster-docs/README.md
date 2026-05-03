# Fonoster Docs Archive

This directory is historical background for the self-hosted Fonoster deployment and early Chatwoot integration planning.

It is no longer the source of truth for the active Onelink/Fonoster voice-agent integration.

## Active Source Of Truth

Use these root-level documents instead:

- `../ONELINK_FONOSTER_VOICE_CONTRACT.md` - canonical production voice/call contract.
- `../ONELINK_EXTERNAL_GEMINI_LIVE_VOICEAPP.md` - deployment/runbook for the Onelink-hosted Gemini Live VoiceApp.
- `../ONELINK_BRIDGE_API_CONTRACT.md` - bridge command API and inbound route/event callbacks.
- `../ONELINK_CRM_GEMINI_SYNC_HANDOFF.md` - short operational handoff/checklist for cross-team production sync.

If any file in this archive conflicts with the active documents, the active root-level documents win.

## Status Of This Directory

The files here can still be useful for:

- historical context
- Fonoster API notes
- old rollout reasoning
- local troubleshooting background

Do not use this directory to tell the Fonoster team what to implement unless the same requirement is present in the active source-of-truth documents.

## Current Production Rule

```text
Fonoster = telephony execution and media bridge
onelink-ai-voice = realtime Gemini Live audio loop
Rails Onelink = CRM truth, context, tools, transcript, routing, finalization
```
