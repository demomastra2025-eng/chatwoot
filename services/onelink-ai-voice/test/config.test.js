const test = require('node:test');
const assert = require('node:assert/strict');
const { loadConfig } = require('../src/config');

test('loadConfig defaults to Gemini Live with production voice model and sulafat voice', () => {
  const config = loadConfig({});

  assert.equal(config.realtimeProvider, 'gemini-live');
  assert.equal(config.geminiModel, 'gemini-3.1-flash-live-preview');
  assert.equal(config.geminiVoice, 'sulafat');
  assert.equal(config.language, 'ru-KZ');
  assert.equal(config.toolTimeoutMs, 3_000);
});

test('loadConfig prefers AI voice internal token while preserving legacy fallback', () => {
  assert.equal(
    loadConfig({ ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-token', ONELINK_INTERNAL_TOKEN: 'legacy-token' }).internalToken,
    'voice-token'
  );
  assert.equal(
    loadConfig({ VOICE_AGENT_ONELINK_AI_SHARED_SECRET: 'contract-token', ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-token' }).internalToken,
    'contract-token'
  );
  assert.equal(loadConfig({ AI_VOICE_INTERNAL_TOKEN: 'short-token' }).internalToken, 'short-token');
  assert.equal(loadConfig({ ONELINK_INTERNAL_TOKEN: 'legacy-token' }).internalToken, 'legacy-token');
});

test('loadConfig accepts Fonoster contract env aliases for Rails and realtime tuning', () => {
  const config = loadConfig({
    VOICE_AGENT_ONELINK_AI_BASE_URL: 'http://rails:3000/',
    VOICE_AGENT_ONELINK_AI_EVENT_PATH: '/custom/event',
    VOICE_AGENT_ONELINK_AI_FINALIZE_PATH: '/custom/finalize',
    VOICE_AGENT_REALTIME_OUTPUT_MAX_BUFFERED_MS: '1500',
    VOICE_AGENT_REALTIME_VAD_PREFIX_PADDING_MS: '140',
    VOICE_AGENT_REALTIME_VAD_SILENCE_DURATION_MS: '320',
    VOICE_AGENT_REALTIME_VAD_START_SENSITIVITY: 'START_SENSITIVITY_LOW',
    VOICE_AGENT_REALTIME_VAD_END_SENSITIVITY: 'END_SENSITIVITY_LOW',
    VOICE_AGENT_REALTIME_TURN_COVERAGE: 'TURN_INCLUDES_ALL_INPUT'
  });

  assert.equal(config.railsBaseUrl, 'http://rails:3000');
  assert.equal(config.eventPath, '/custom/event');
  assert.equal(config.finalizePath, '/custom/finalize');
  assert.equal(config.outputMaxBufferedMs, 1500);
  assert.equal(config.prefixPaddingMs, 140);
  assert.equal(config.silenceDurationMs, 320);
  assert.equal(config.speechStartSensitivity, 'START_SENSITIVITY_LOW');
  assert.equal(config.speechEndSensitivity, 'END_SENSITIVITY_LOW');
  assert.equal(config.turnCoverage, 'TURN_INCLUDES_ALL_INPUT');
});
