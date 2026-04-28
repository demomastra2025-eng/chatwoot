const test = require('node:test');
const assert = require('node:assert/strict');
const { SessionRegistry } = require('../src/sessions/session-registry');

test('SessionRegistry creates, retrieves and closes call sessions with bounded history', () => {
  const registry = new SessionRegistry({ ttlMs: 60_000, maxHistory: 2 });
  const session = registry.create({ callRef: 'call-1', accountId: 7, context: { ai: { model: 'gemini-live' } } });

  session.addTranscript({ speaker: 'caller', text: 'hello', final: false, at: '2026-04-28T00:00:00Z' });
  session.addTranscript({ speaker: 'ai', text: 'hi', final: true, at: '2026-04-28T00:00:01Z' });
  session.addTranscript({ speaker: 'caller', text: 'need help', final: true, at: '2026-04-28T00:00:02Z' });
  session.addControlEvent('ai_answered', { provider: 'gemini-live' });

  assert.equal(registry.get('call-1'), session);
  assert.equal(session.transcript.length, 2);
  assert.deepEqual(session.transcript.map((item) => item.text), ['hi', 'need help']);
  assert.equal(session.controlEvents[0].action, 'ai_answered');

  registry.close('call-1', 'completed');
  assert.equal(session.state, 'completed');
  assert.equal(registry.get('call-1'), undefined);
});

test('SessionRegistry sweeps expired sessions deterministically', () => {
  let now = 1_000;
  const registry = new SessionRegistry({ ttlMs: 100, now: () => now });
  registry.create({ callRef: 'old' });
  now = 1_101;
  assert.equal(registry.sweep(), 1);
  assert.equal(registry.get('old'), undefined);
});
