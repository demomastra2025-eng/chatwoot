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
    internalToken: env.VOICE_AGENT_ONELINK_AI_SHARED_SECRET || env.ONELINK_AI_VOICE_INTERNAL_TOKEN || env.AI_VOICE_INTERNAL_TOKEN ||
      env.VOICE_AGENT_INTERNAL_TOKEN || env.ONELINK_INTERNAL_SECRET || env.ONELINK_INTERNAL_TOKEN || '',
    contextPath: env.VOICE_AGENT_ONELINK_AI_CONTEXT_PATH || '/internal/voice/ai/context',
    transcriptPath: env.VOICE_AGENT_ONELINK_AI_TRANSCRIPT_PATH || '/internal/voice/ai/transcript',
    controlPath: env.VOICE_AGENT_ONELINK_AI_CONTROL_PATH || '/internal/voice/ai/control',
    eventPath: env.VOICE_AGENT_ONELINK_AI_EVENT_PATH || '/internal/voice/ai/event',
    finalizePath: env.VOICE_AGENT_ONELINK_AI_FINALIZE_PATH || '/internal/voice/ai/finalize',
    grpcPort: parseInteger(env.VOICE_AGENT_GRPC_PORT || env.VOICE_AGENT_PORT, 50061),
    skipIdentity: parseBoolean(env.VOICE_AGENT_SKIP_IDENTITY, false),
    identityAddress: env.VOICE_AGENT_IDENTITY_ADDRESS || '',
    apiPort: parseInteger(env.VOICE_AGENT_API_PORT, 8081),
    sessionTtlMs: parseInteger(env.VOICE_AGENT_SESSION_TTL_MS, 3_600_000),
    toolTimeoutMs: parseInteger(env.VOICE_AGENT_TOOL_TIMEOUT_MS, 3_000),
    realtimeProvider: env.VOICE_AGENT_REALTIME_PROVIDER || 'gemini-live',
    geminiApiKey: env.VOICE_AGENT_REALTIME_API_KEY || env.GEMINI_API_KEY || env.GOOGLE_API_KEY || '',
    geminiModel: env.VOICE_AGENT_REALTIME_MODEL || 'gemini-3.1-flash-live-preview',
    geminiVoice: env.VOICE_AGENT_REALTIME_VOICE || 'sulafat',
    language: env.VOICE_AGENT_LANGUAGE || env.VOICE_AGENT_REALTIME_LANGUAGE || 'ru-KZ',
    temperature: parseFloatValue(env.VOICE_AGENT_REALTIME_TEMPERATURE, 0.3),
    maxOutputTokens: parseInteger(env.VOICE_AGENT_REALTIME_MAX_OUTPUT_TOKENS, 120),
    setupTimeoutMs: parseInteger(env.VOICE_AGENT_REALTIME_SETUP_TIMEOUT_MS, 15_000),
    interruptions: !['0', 'false', 'off', 'no'].includes(String(env.VOICE_AGENT_REALTIME_INTERRUPTS || 'true').trim().toLowerCase()),
    startupBeeps: parseBoolean(env.VOICE_AGENT_REALTIME_STARTUP_BEEPS, false),
    outputMaxBufferedMs: parseInteger(env.VOICE_AGENT_REALTIME_OUTPUT_MAX_BUFFERED_MS, 5_000),
    clearAudioOnInterrupt: parseBoolean(env.VOICE_AGENT_CLEAR_AUDIO_ON_INTERRUPT ?? env.VOICE_AGENT_REALTIME_CLEAR_AUDIO_ON_INTERRUPT, true),
    speechStartSensitivity: env.VOICE_AGENT_REALTIME_VAD_START_SENSITIVITY || env.VOICE_AGENT_REALTIME_START_SENSITIVITY || 'START_SENSITIVITY_HIGH',
    speechEndSensitivity: env.VOICE_AGENT_REALTIME_VAD_END_SENSITIVITY || env.VOICE_AGENT_REALTIME_END_SENSITIVITY || 'END_SENSITIVITY_HIGH',
    prefixPaddingMs: parseInteger(env.VOICE_AGENT_REALTIME_VAD_PREFIX_PADDING_MS || env.VOICE_AGENT_REALTIME_PREFIX_PADDING_MS, 120),
    silenceDurationMs: parseInteger(env.VOICE_AGENT_REALTIME_VAD_SILENCE_DURATION_MS || env.VOICE_AGENT_REALTIME_SILENCE_DURATION_MS, 300),
    turnCoverage: env.VOICE_AGENT_REALTIME_TURN_COVERAGE || 'TURN_INCLUDES_ONLY_ACTIVITY'
  };
}

module.exports = { loadConfig, parseInteger, parseBoolean, parseFloatValue };
