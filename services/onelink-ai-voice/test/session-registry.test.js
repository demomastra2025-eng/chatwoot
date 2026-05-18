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

test('SessionRegistry closes an active session by any lifecycle alias', () => {
  const registry = new SessionRegistry({ ttlMs: 60_000 });
  const session = registry.create({
    callRef: 'runtime-ref',
    bridge_call_ref: 'bridge-ref',
    child_call_ref: 'child-ref',
    media_session_ref: 'media-ref'
  });

  registry.update('runtime-ref', {
    stream_ref: 'stream-ref',
    routeDecision: { parent_call_ref: 'parent-ref' }
  });

  assert.equal(registry.activeCount(), 1);
  assert.equal(registry.get('bridge-ref'), session);
  assert.equal(registry.get('media-ref'), session);
  assert.equal(registry.get('stream-ref'), session);
  assert.equal(registry.get('parent-ref'), session);

  registry.close('parent-ref', 'cancelled');

  assert.equal(session.state, 'cancelled');
  assert.equal(registry.activeCount(), 0);
  assert.equal(registry.get('runtime-ref'), undefined);
  assert.equal(registry.get('bridge-ref'), undefined);
  assert.equal(registry.get('media-ref'), undefined);
  assert.equal(registry.get('stream-ref'), undefined);
});

test('SessionRegistry activeCount excludes terminal retained sessions', () => {
  const registry = new SessionRegistry({ ttlMs: 60_000 });
  registry.create({ callRef: 'active' });
  registry.create({ callRef: 'failed' });
  registry.create({ callRef: 'closed-after-audio' });
  registry.create({ callRef: 'caller-ended' });
  registry.update('failed', { state: 'failed' });
  registry.update('closed-after-audio', { state: 'media_stream_closed_after_audio' });
  registry.update('caller-ended', { state: 'caller_hung_up' });

  assert.equal(registry.sessions.size, 4);
  assert.equal(registry.activeCount(), 1);
});
