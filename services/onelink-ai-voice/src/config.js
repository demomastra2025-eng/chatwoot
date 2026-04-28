function parseInteger(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseBoolean(value, fallback = false) {
  if (value === undefined || value === null || value === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(value).trim().toLowerCase());
}

function loadConfig(env = process.env) {
  return {
    railsBaseUrl: (env.ONELINK_INTERNAL_BASE_URL || env.CHATWOOT_INTERNAL_BASE_URL || 'http://127.0.0.1:3000').replace(/\/+$/, ''),
    internalToken: env.ONELINK_INTERNAL_TOKEN || env.ONELINK_AI_VOICE_INTERNAL_TOKEN || env.VOICE_AGENT_INTERNAL_TOKEN || '',
    grpcPort: parseInteger(env.VOICE_AGENT_GRPC_PORT || env.VOICE_AGENT_PORT, 50061),
    skipIdentity: parseBoolean(env.VOICE_AGENT_SKIP_IDENTITY, false),
    identityAddress: env.VOICE_AGENT_IDENTITY_ADDRESS || '',
    apiPort: parseInteger(env.VOICE_AGENT_API_PORT, 8081),
    sessionTtlMs: parseInteger(env.VOICE_AGENT_SESSION_TTL_MS, 3_600_000),
    toolTimeoutMs: parseInteger(env.VOICE_AGENT_TOOL_TIMEOUT_MS, 800),
    realtimeProvider: env.VOICE_AGENT_REALTIME_PROVIDER || 'gemini-live',
    geminiApiKey: env.VOICE_AGENT_REALTIME_API_KEY || env.GEMINI_API_KEY || env.GOOGLE_API_KEY || '',
    geminiModel: env.VOICE_AGENT_REALTIME_MODEL || 'gemini-2.0-flash-live-001',
    geminiVoice: env.VOICE_AGENT_REALTIME_VOICE || 'Puck',
    language: env.VOICE_AGENT_LANGUAGE || env.VOICE_AGENT_REALTIME_LANGUAGE || 'ru-KZ',
    setupTimeoutMs: parseInteger(env.VOICE_AGENT_REALTIME_SETUP_TIMEOUT_MS, 15_000),
    interruptions: !['0', 'false', 'off', 'no'].includes(String(env.VOICE_AGENT_REALTIME_INTERRUPTS || 'true').trim().toLowerCase())
  };
}

module.exports = { loadConfig, parseInteger, parseBoolean };
