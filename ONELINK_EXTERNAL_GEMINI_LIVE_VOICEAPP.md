# Onelink-Hosted Gemini Live VoiceApp

Deployment/runbook document for the Onelink-hosted Gemini Live voice service.
Last updated: 2026-05-03.

The full behavior contract is in `ONELINK_FONOSTER_VOICE_CONTRACT.md`. Do not duplicate schemas from that file here.

## Purpose

Gemini Live must run on the Onelink side, but not inside Rails.

Correct production shape:

```text
Fonoster server
  PSTN/SIP, Asterisk/Routr/RTP, app refs, call routing execution, media bridge

Onelink server
  Rails CRM, business state, AI config, prompts, tools, transcripts, finalization

onelink-ai-voice
  separate Node service next to Rails, owns Fonoster VoiceServer and Gemini Live realtime audio loop
```

Rails receives JSON/context/tools/transcript/events/finalize only. Rails must never receive every audio frame.

## What Fonoster Must Configure

Create or update one Fonoster `EXTERNAL` application:

```json
{
  "name": "Onelink Gemini Live Voice Agent",
  "type": "EXTERNAL",
  "endpoint": "<private-onelink-ai-voice-host>:50061"
}
```

The endpoint must be reachable from the Fonoster `apiserver` container.

Fonoster team needs only:

```text
voice_app_endpoint=<private-onelink-ai-voice-host>:50061
voice_app_health_endpoint=<private-onelink-ai-voice-host>:8081, optional
network_policy=private network, VPN, or strict source-IP allowlist
app_ref=<Fonoster app ref for this EXTERNAL application>
```

Fonoster team does not need Rails secrets, Gemini keys, prompt config, customer context, or CRM tools.

## What Must Be Removed From Fonoster Env

When this service is live, remove AI ownership from the Fonoster server:

```text
GEMINI_API_KEY
GOOGLE_API_KEY
VOICE_AGENT_REALTIME_API_KEY
prompt/tool/customer config
local test-voiceapp as production app target
```

Fonoster keeps only app refs, bridge config, SIP/trunk/number resources, and technical fallback.

## Required Fonoster Stream Support

The running Fonoster image must support bidirectional streaming:

```text
AUDIO_IN:  caller -> onelink-ai-voice
AUDIO_OUT: onelink-ai-voice -> caller
```

If `AUDIO_OUT` is missing, Gemini will hear the caller but the caller will not hear Gemini.

## Network Rule

`50061` is gRPC and must be private.

Use one of:

```text
WireGuard/Tailscale/private VPC
firewall allowlist from Fonoster server IP for testing
TLS/mTLS only if public exposure is unavoidable and implemented on both sides
```

Do not expose `50061` openly to the internet.

First operational check:

```text
Fonoster server -> onelink-ai-voice TCP 50061
```

Only after this passes should the Fonoster app endpoint/app ref be switched.

## onelink-ai-voice Responsibilities

The service must:

1. Start a Fonoster `VoiceServer` on `50061`.
2. Answer the call.
3. Fetch AI context from Rails via `POST /internal/voice/ai/context`.
4. Start bidirectional voice stream.
5. Open one Gemini Live websocket per active call.
6. Send caller PCM audio to Gemini.
7. Receive Gemini PCM audio.
8. Resample Gemini output to call rate.
9. Write audio back to Fonoster as `AUDIO_OUT`.
10. Clear playback buffer on interruption/barge-in.
11. Send transcript batches to Rails asynchronously.
12. Send lifecycle/error/tool/transfer events to Rails asynchronously.
13. Execute Gemini tool calls through Rails.
14. Transfer to operator only after Rails authorizes target.
15. Call `/internal/voice/ai/finalize` exactly once per terminal session, with idempotent retry.
16. Close Gemini, stream, timers, and session state on hangup.

## Recommended Runtime Env

```env
NODE_ENV=production
LOG_LEVEL=info

VOICE_AGENT_GRPC_PORT=50061
VOICE_AGENT_API_PORT=8081
VOICE_AGENT_VOICE_MODE=realtime
VOICE_AGENT_REALTIME_PROVIDER=gemini-live
VOICE_AGENT_REALTIME_MODEL=gemini-3.1-flash-live-preview
VOICE_AGENT_REALTIME_INPUT_RATE=16000
VOICE_AGENT_REALTIME_OUTPUT_RATE=24000
VOICE_AGENT_REALTIME_CALL_RATE=8000
VOICE_AGENT_REALTIME_INTERRUPTS=true
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
VOICE_AGENT_ONELINK_AI_CONTROL_PATH=/internal/voice/ai/control
VOICE_AGENT_ONELINK_AI_EVENT_PATH=/internal/voice/ai/event
VOICE_AGENT_ONELINK_AI_FINALIZE_PATH=/internal/voice/ai/finalize

# Tool endpoint is currently fixed in the runtime as /internal/voice/ai/tools/:name.
# Rails controls exposed tool names through the AI context response.

GEMINI_API_KEY=${GEMINI_API_KEY}
```

`VOICE_AGENT_REALTIME_CALL_RATE=8000` matches the current telephony output path. Change it only after the Fonoster stream output path is patched and tested for another call rate.

The runtime also supports legacy/internal env aliases for base URL, token, event, and finalize paths. Do not add new tool-path or tool-name env variables unless the deployed runtime code supports them. Tool names are controlled by Rails context.

## Gemini Live Config Shape

Use native Gemini Live audio. Do not add Deepgram STT or external TTS in this path.

Recommended shape:

```json
{
  "responseModalities": ["AUDIO"],
  "temperature": 0.3,
  "maxOutputTokens": 120,
  "speechConfig": {
    "voiceConfig": {
      "prebuiltVoiceConfig": {
        "voiceName": "Sulafat"
      }
    }
  },
  "thinkingConfig": {
    "thinkingLevel": "minimal"
  },
  "realtimeInputConfig": {
    "automaticActivityDetection": {
      "disabled": false,
      "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
      "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH",
      "prefixPaddingMs": 120,
      "silenceDurationMs": 300
    },
    "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
    "turnCoverage": "TURN_INCLUDES_ONLY_ACTIVITY"
  },
  "inputAudioTranscription": {},
  "outputAudioTranscription": {}
}
```

Treat the model name as deployment config. Before production, verify the selected Gemini Live model is enabled in the Google project used by `GEMINI_API_KEY`.

## Latency Rules

For fast voice behavior:

- open Gemini immediately after answer
- remove startup beeps in production
- avoid `voice.say()` before Gemini unless legally required
- keep prompt short
- cap output to about `80-160` tokens
- do not perform Rails DB writes inline in the audio callback
- batch transcript writes
- keep playback buffer around `500-1500ms`
- clear playback buffer on interruption
- use one Gemini websocket per active call
- scale by running multiple `onelink-ai-voice` instances behind distinct Fonoster app refs or a private load-balanced endpoint that preserves active gRPC sessions

## Deployment Sketch

```yaml
services:
  onelink-ai-voice:
    image: onelink/ai-voice:latest
    restart: unless-stopped
    environment:
      VOICE_AGENT_GRPC_PORT: "50061"
      VOICE_AGENT_API_PORT: "8081"
      VOICE_AGENT_VOICE_MODE: realtime
      VOICE_AGENT_REALTIME_PROVIDER: gemini-live
      VOICE_AGENT_REALTIME_MODEL: gemini-3.1-flash-live-preview
      VOICE_AGENT_REALTIME_INPUT_RATE: "16000"
      VOICE_AGENT_REALTIME_OUTPUT_RATE: "24000"
      VOICE_AGENT_REALTIME_CALL_RATE: "8000"
      VOICE_AGENT_REALTIME_GREETING_MODE: provider
      VOICE_AGENT_REALTIME_STARTUP_BEEPS: "false"
      VOICE_AGENT_REALTIME_OUTPUT_MAX_BUFFERED_MS: "1500"
      VOICE_AGENT_REALTIME_MAX_OUTPUT_TOKENS: "120"
      VOICE_AGENT_ONELINK_AI_BASE_URL: http://rails:3000
      VOICE_AGENT_ONELINK_AI_SHARED_SECRET: ${ONELINK_INTERNAL_SECRET}
      GEMINI_API_KEY: ${GEMINI_API_KEY}
    ports:
      - "10.0.0.20:50061:50061"
      - "127.0.0.1:8081:8081"
```

Replace `10.0.0.20` with the private interface reachable from Fonoster.

## Validation Checklist

Before live traffic:

1. Fonoster can reach `<private-onelink-ai-voice-host>:50061`.
2. Fonoster application endpoint is not `test-voiceapp:50061`.
3. Fonoster image has bidirectional stream support.
4. Rails and `onelink-ai-voice` share the same internal voice token.
5. Gemini key exists only on the Onelink side.
6. Inbound AI call returns audio both ways.
7. Outbound AI call uses the Onelink AI app ref.
8. Interruption clears playback.
9. Transcript reaches Onelink.
10. `/internal/voice/ai/event` deduplicates events.
11. `/internal/voice/ai/finalize` is idempotent.
12. Transfer to operator works.
13. Operator no-answer finalizes `operator_unavailable`.
14. Gemini failure fallback works.
15. Rails context timeout fallback works.

For the cross-team synchronization checklist, use:

```text
ONELINK_CRM_GEMINI_SYNC_HANDOFF.md
```

## Final Architecture Rule

```text
Fonoster = telephony and media bridge
onelink-ai-voice = realtime Gemini Live voice loop
Rails = CRM truth, context, tools, transcript, routing, finalization
```
