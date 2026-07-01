const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeAiResponseText } = require('../src/transcripts/ai-response-normalizer');
const { VoiceSession } = require('../src/sessions/voice-session');

test('normalizeAiResponseText extracts spoken response and keeps reasoning out-of-band', () => {
  const raw = JSON.stringify({
    reasoning: 'Greet the caller first.',
    response: 'Здравствуйте! Чем могу помочь?',
    artifact_ids: ['doc-1'],
    handoff_reason: 'internal only'
  });

  assert.deepEqual(normalizeAiResponseText(raw), {
    text: 'Здравствуйте! Чем могу помочь?',
    normalized: true,
    raw_text: raw,
    reasoning: 'Greet the caller first.',
    artifact_ids: ['doc-1'],
    handoff_reason: 'internal only',
    normalized_from: 'captain_json_response'
  });
});

test('normalizeAiResponseText treats visible response aliases as spoken text', () => {
  const raw = JSON.stringify({ answer: 'Да, мы работаем сегодня.' });

  assert.deepEqual(normalizeAiResponseText(raw), {
    text: 'Да, мы работаем сегодня.',
    normalized: true,
    raw_text: raw,
    normalized_from: 'captain_json_response'
  });
});

test('VoiceSession sends normalized AI transcript items instead of raw Captain JSON', async () => {
  const sentTranscripts = [];
  const client = {
    sendTranscript: async payload => { sentTranscripts.push(payload); return { status: 'ok', accepted: payload.items.length }; },
    sendEvent: async () => ({ status: 'ok' }),
    sendControl: async () => ({ status: 'ok' })
  };
  const session = new VoiceSession({ client, callRef: 'voice-json-call-1', accountId: 6 });
  session.context = { account_id: 6 };
  const raw = JSON.stringify({ reasoning: 'Greet naturally.', response: 'Здравствуйте!' });

  const item = session.recordAiTranscript(raw, { final: true, at: '2026-07-01T04:20:15.000Z' });
  await session.transcriptFlushPromise;

  assert.equal(item.text, 'Здравствуйте!');
  assert.equal(item.raw_text, raw);
  assert.equal(sentTranscripts.length, 1);
  assert.deepEqual(sentTranscripts[0].items[0], {
    speaker: 'ai',
    text: 'Здравствуйте!',
    final: true,
    at: '2026-07-01T04:20:15.000Z',
    raw_text: raw,
    reasoning: 'Greet naturally.',
    normalized_from: 'captain_json_response'
  });
});
