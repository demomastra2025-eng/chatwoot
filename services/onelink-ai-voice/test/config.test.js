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
  assert.equal(loadConfig({ AI_VOICE_INTERNAL_TOKEN: 'short-token' }).internalToken, 'short-token');
  assert.equal(loadConfig({ ONELINK_INTERNAL_TOKEN: 'legacy-token' }).internalToken, 'legacy-token');
});
