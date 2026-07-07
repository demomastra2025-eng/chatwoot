function parseInteger(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseBoolean(value, fallback = false) {
  if (value === undefined || value === null || value === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(value).trim().toLowerCase());
}

function parseFloatValue(value, fallback) {
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function loadConfig(env = process.env) {
  return {
    railsBaseUrl: (
      env.VOICE_AGENT_ONELINK_AI_BASE_URL ||
      env.ONELINK_INTERNAL_BASE_URL ||
      env.CHATWOOT_INTERNAL_BASE_URL ||
      'http://127.0.0.1:3000'
    ).replace(/\/+$/, ''),
    internalToken: env.ONELINK_AI_VOICE_INTERNAL_TOKEN || env.AI_VOICE_INTERNAL_TOKEN || env.VOICE_AGENT_ONELINK_AI_SHARED_SECRET ||
      env.VOICE_AGENT_INTERNAL_TOKEN || env.ONELINK_INTERNAL_SECRET || env.ONELINK_INTERNAL_TOKEN || '',
    bridgeToken: env.TELEPHONY_BRIDGE_ONELINK_ACCESS_TOKEN || env.TELEPHONY_BRIDGE_ACCESS_TOKEN || env.TELEPHONY_BRIDGE_SHARED_SECRET || '',
    contextPath: env.VOICE_AGENT_ONELINK_AI_CONTEXT_PATH || '/internal/voice/ai/context',
    transcriptPath: env.VOICE_AGENT_ONELINK_AI_TRANSCRIPT_PATH || '/internal/voice/ai/transcript',
    controlPath: env.VOICE_AGENT_ONELINK_AI_CONTROL_PATH || '/internal/voice/ai/control',
    eventPath: env.VOICE_AGENT_ONELINK_AI_EVENT_PATH || '/internal/voice/ai/event',
    finalizePath: env.VOICE_AGENT_ONELINK_AI_FINALIZE_PATH || '/internal/voice/ai/finalize',
    apiPort: parseInteger(env.VOICE_AGENT_API_PORT, 8081),
    janusAttachPath: env.VOICE_AGENT_JANUS_ATTACH_PATH || env.ONELINK_AI_VOICE_JANUS_ATTACH_PATH || env.AI_VOICE_JANUS_ATTACH_PATH || '/internal/janus-sip/calls',
    janusAllowedProviders: parseList(env.VOICE_AGENT_JANUS_ALLOWED_PROVIDERS || env.ONELINK_AI_VOICE_JANUS_ALLOWED_PROVIDERS || ''),
    janusAdminUrl: env.VOICE_AGENT_JANUS_ADMIN_URL || env.ONELINK_AI_VOICE_JANUS_ADMIN_URL || env.JANUS_ADMIN_URL || '',
    janusAdminSecret: env.VOICE_AGENT_JANUS_ADMIN_SECRET || env.ONELINK_AI_VOICE_JANUS_ADMIN_SECRET || env.JANUS_ADMIN_SECRET || '',
    janusSipAdminKey: env.VOICE_AGENT_JANUS_SIP_ADMIN_KEY || env.ONELINK_AI_VOICE_JANUS_SIP_ADMIN_KEY || env.JANUS_SIP_ADMIN_KEY || '',
    janusRtpForwardHost: env.VOICE_AGENT_JANUS_RTP_FORWARD_HOST || env.ONELINK_AI_VOICE_JANUS_RTP_FORWARD_HOST || '',
    janusRtpForwardHostFamily: env.VOICE_AGENT_JANUS_RTP_FORWARD_HOST_FAMILY || env.ONELINK_AI_VOICE_JANUS_RTP_FORWARD_HOST_FAMILY || 'ipv4',
    janusRtpForwardPeerAudioPort: parseInteger(env.VOICE_AGENT_JANUS_RTP_FORWARD_PEER_AUDIO_PORT || env.ONELINK_AI_VOICE_JANUS_RTP_FORWARD_PEER_AUDIO_PORT, 0),
    janusRtpForwardAudioPort: parseInteger(env.VOICE_AGENT_JANUS_RTP_FORWARD_AUDIO_PORT || env.ONELINK_AI_VOICE_JANUS_RTP_FORWARD_AUDIO_PORT, 0),
    janusRtpForwardPayloadType: parseInteger(env.VOICE_AGENT_JANUS_RTP_FORWARD_PAYLOAD_TYPE || env.ONELINK_AI_VOICE_JANUS_RTP_FORWARD_PAYLOAD_TYPE, 0),
    janusRtpBridgeEnabled: parseBoolean(env.VOICE_AGENT_JANUS_RTP_BRIDGE_ENABLED || env.ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_ENABLED, false),
    janusRtpBridgeListenHost: env.VOICE_AGENT_JANUS_RTP_BRIDGE_LISTEN_HOST || env.ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_LISTEN_HOST || '0.0.0.0',
    janusRtpBridgeListenPort: parseInteger(env.VOICE_AGENT_JANUS_RTP_BRIDGE_LISTEN_PORT || env.ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_LISTEN_PORT, 0),
    janusRtpBridgePublicHost: env.VOICE_AGENT_JANUS_RTP_BRIDGE_PUBLIC_HOST || env.ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_PUBLIC_HOST || env.VOICE_AGENT_JANUS_RTP_FORWARD_HOST || '',
    janusRtpBridgeInputCodec: env.VOICE_AGENT_JANUS_RTP_BRIDGE_INPUT_CODEC || env.ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_INPUT_CODEC || 'pcmu',
    janusRtpBridgeOutputCodec: env.VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_CODEC || env.ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_OUTPUT_CODEC || 'pcmu',
    janusRtpBridgeOutputHost: env.VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_HOST || env.ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_OUTPUT_HOST || '',
    janusRtpBridgeOutputPort: parseInteger(env.VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_PORT || env.ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_OUTPUT_PORT, 0),
    janusRtpBridgeOutputPayloadType: parseInteger(env.VOICE_AGENT_JANUS_RTP_BRIDGE_OUTPUT_PAYLOAD_TYPE || env.ONELINK_AI_VOICE_JANUS_RTP_BRIDGE_OUTPUT_PAYLOAD_TYPE, 0),
    janusBrowserBridgeEnabled: parseBoolean(env.VOICE_AGENT_JANUS_BROWSER_BRIDGE_ENABLED || env.ONELINK_AI_VOICE_JANUS_BROWSER_BRIDGE_ENABLED, false),
    janusBrowserBridgePath: env.VOICE_AGENT_JANUS_BROWSER_BRIDGE_PATH || env.ONELINK_AI_VOICE_JANUS_BROWSER_BRIDGE_PATH || '/ai-voice/janus-sip/browser-media',
    janusBrowserBridgePublicBaseUrl: (env.VOICE_AGENT_PUBLIC_BASE_URL || env.ONELINK_AI_VOICE_PUBLIC_BASE_URL || '').replace(/\/+$/, ''),
    whatsappAttachPath: env.VOICE_AGENT_WHATSAPP_ATTACH_PATH || env.ONELINK_AI_VOICE_WHATSAPP_ATTACH_PATH || env.AI_VOICE_WHATSAPP_ATTACH_PATH || '/internal/whatsapp-cloud/calls',
    sessionTtlMs: parseInteger(env.VOICE_AGENT_SESSION_TTL_MS, 3_600_000),
    onelinkTimeoutMs: parseInteger(env.VOICE_AGENT_ONELINK_TIMEOUT_MS || env.VOICE_AGENT_ONELINK_AI_TIMEOUT_MS, 10_000),
    contextBootstrapTimeoutMs: parseInteger(env.VOICE_AGENT_CONTEXT_BOOTSTRAP_TIMEOUT_MS || env.VOICE_AGENT_CONTEXT_TIMEOUT_MS, 2_500),
    toolTimeoutMs: parseInteger(env.VOICE_AGENT_TOOL_TIMEOUT_MS, 3_000),
    realtimeProvider: env.VOICE_AGENT_REALTIME_PROVIDER || 'gemini-live',
    geminiApiKey: env.VOICE_AGENT_REALTIME_API_KEY || env.GEMINI_API_KEY || env.GOOGLE_API_KEY || '',
    geminiModel: env.VOICE_AGENT_REALTIME_MODEL || 'gemini-3.1-flash-live-preview',
    geminiVoice: env.VOICE_AGENT_REALTIME_VOICE || 'sulafat',
    language: env.VOICE_AGENT_LANGUAGE || env.VOICE_AGENT_REALTIME_LANGUAGE || 'ru-KZ',
    temperature: parseFloatValue(env.VOICE_AGENT_REALTIME_TEMPERATURE, 0.3),
    maxOutputTokens: parseInteger(env.VOICE_AGENT_REALTIME_MAX_OUTPUT_TOKENS, 1024),
    setupTimeoutMs: parseInteger(env.VOICE_AGENT_REALTIME_SETUP_TIMEOUT_MS, 15_000),
    interruptions: !['0', 'false', 'off', 'no'].includes(String(env.VOICE_AGENT_REALTIME_INTERRUPTS || 'true').trim().toLowerCase()),
    interruptionMode: env.VOICE_AGENT_REALTIME_INTERRUPTION_MODE || 'transcript_confirmed',
    startupBeeps: parseBoolean(env.VOICE_AGENT_REALTIME_STARTUP_BEEPS, false),
    outputMaxBufferedMs: parseInteger(env.VOICE_AGENT_REALTIME_OUTPUT_MAX_BUFFERED_MS, 15_000),
    postToolContinuationMs: parseInteger(env.VOICE_AGENT_POST_TOOL_CONTINUATION_MS || env.VOICE_AGENT_REALTIME_POST_TOOL_CONTINUATION_MS, 4_000),
    clearAudioOnInterrupt: parseBoolean(env.VOICE_AGENT_CLEAR_AUDIO_ON_INTERRUPT ?? env.VOICE_AGENT_REALTIME_CLEAR_AUDIO_ON_INTERRUPT, false),
    speechStartSensitivity: env.VOICE_AGENT_REALTIME_VAD_START_SENSITIVITY || env.VOICE_AGENT_REALTIME_START_SENSITIVITY || 'START_SENSITIVITY_HIGH',
    speechEndSensitivity: env.VOICE_AGENT_REALTIME_VAD_END_SENSITIVITY || env.VOICE_AGENT_REALTIME_END_SENSITIVITY || 'END_SENSITIVITY_HIGH',
    prefixPaddingMs: parseInteger(env.VOICE_AGENT_REALTIME_VAD_PREFIX_PADDING_MS || env.VOICE_AGENT_REALTIME_PREFIX_PADDING_MS, 120),
    silenceDurationMs: parseInteger(env.VOICE_AGENT_REALTIME_VAD_SILENCE_DURATION_MS || env.VOICE_AGENT_REALTIME_SILENCE_DURATION_MS, 300),
    turnCoverage: env.VOICE_AGENT_REALTIME_TURN_COVERAGE || 'TURN_INCLUDES_ONLY_ACTIVITY'
  };
}

module.exports = { loadConfig, parseInteger, parseBoolean, parseFloatValue };

function parseList(value) {
  return String(value || '')
    .split(',')
    .map(item => item.trim().toLowerCase())
    .filter(Boolean);
}

module.exports.parseList = parseList;
