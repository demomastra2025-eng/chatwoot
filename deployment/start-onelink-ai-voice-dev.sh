#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -z "${line}" ]] && continue
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ "${line}" != *=* ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  export "${key}=${value}"
done < /srv/onelink-dev/.env.development

export VOICE_AGENT_API_PORT=8082
export VOICE_AGENT_ONELINK_AI_BASE_URL=http://127.0.0.1:3002
export ONELINK_INTERNAL_BASE_URL=http://127.0.0.1:3002
export ONELINK_AI_VOICE_BASE_URL=http://127.0.0.1:8082
export AI_VOICE_BASE_URL=http://127.0.0.1:8082
export VOICE_AGENT_JANUS_ATTACH_PATH=/internal/janus-sip/calls
export VOICE_AGENT_JANUS_RTP_BRIDGE_ENABLED=false
export VOICE_AGENT_JANUS_BROWSER_BRIDGE_ENABLED=true
export VOICE_AGENT_JANUS_BROWSER_BRIDGE_PATH=/ai-voice/janus-sip/browser-media
export VOICE_AGENT_PUBLIC_BASE_URL=wss://dev.one-link.kz
export VOICE_AGENT_TOOL_TIMEOUT_MS=3000
export VOICE_AGENT_CONTEXT_BOOTSTRAP_TIMEOUT_MS=2500
export VOICE_AGENT_INITIAL_MEDIA_KEEPALIVE_MS=15000
export VOICE_AGENT_INITIAL_GREETING_RETRY_MS=2500
export VOICE_AGENT_RECORDING_ROOT=/srv/onelink-dev/onelink/chatwoot/storage
export ONELINK_AI_VOICE_PIPECAT_ENABLED=true
export ONELINK_AI_VOICE_PIPECAT_BASE_URL=http://127.0.0.1:18084
# Pipecat runs on the same DEV host. Keep terminal control on loopback so the
# reverse proxy cannot strip the /ai-voice prefix from capability-scoped URLs.
export ONELINK_AI_VOICE_PIPECAT_CONTROL_BASE_URL=http://127.0.0.1:8082
export ONELINK_AI_VOICE_PIPECAT_CONTROL_PATH=/ai-voice/internal/pipecat/runtime-control
export ONELINK_AI_VOICE_PIPECAT_PROVIDERS=sipuni,asterisk_analog
export ONELINK_AI_VOICE_PIPECAT_ACCOUNT_IDS=530
export ONELINK_AI_VOICE_PIPECAT_CHANNEL_IDS=4778,4865
export ONELINK_AI_VOICE_PIPECAT_PERCENTAGE=100
export PATH=/opt/node-24/bin:${PATH}

cd /srv/onelink-dev/onelink/chatwoot/services/onelink-ai-voice
exec /opt/node-24/bin/npm start
