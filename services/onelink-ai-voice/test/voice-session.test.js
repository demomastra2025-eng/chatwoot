const test = require('node:test');
const assert = require('node:assert/strict');
const { VoiceSession } = require('../src/sessions/voice-session');

test('VoiceSession bootstraps Rails context, records lifecycle and flushes transcripts', async () => {
  const calls = [];
  const client = {
    getContext: async () => ({
      call_ref: 'call-1',
      account_id: 42,
      number_ref: 'num-1',
      ai: { provider: 'gemini-live', model: 'gemini-2.0-flash-live-001', first_message: 'Здравствуйте' },
      transfer: { enabled: true, operator_agent_aor: 'sip:1001@example.test' },
      tools: [{ name: 'request_transfer', enabled: true }]
    }),
    sendControl: async (payload) => { calls.push(['control', payload]); return { status: 'ok' }; },
    sendTranscript: async (payload) => { calls.push(['transcript', payload]); return { status: 'ok' }; },
    callTool: async (name, payload) => { calls.push(['tool', name, payload]); return { action: name === 'request_transfer' ? 'transfer' : 'noop', operator_agent_aor: 'sip:1001@example.test' }; }
  };

  const session = new VoiceSession({ client, callRef: 'call-1', ingressNumber: '+7000', callerNumber: '+7999' });
  const context = await session.bootstrap();
  session.recordCallerTranscript('Мне нужен оператор', { final: true, at: 't1' });
  const toolResult = await session.executeTool('request_transfer', { reason: 'caller_requested_operator' });
  await session.close('session_completed');

  assert.equal(context.ai.provider, 'gemini-live');
  assert.equal(toolResult.result.action, 'transfer');
  assert.deepEqual(
    calls.filter(([kind]) => kind === 'control').map(([, payload]) => payload.action),
    ['ai_ringing', 'ai_answered', 'tool_started', 'tool_completed', 'session_completed']
  );
  const transcriptCall = calls.find(([kind]) => kind === 'transcript');
  assert.equal(transcriptCall[1].account_id, 42);
  assert.equal(transcriptCall[1].number_ref, 'num-1');
  assert.equal(transcriptCall[1].items[0].text, 'Мне нужен оператор');
  const toolCall = calls.find(([kind]) => kind === 'tool');
  assert.equal(toolCall[2].account_id, 42);
  assert.equal(toolCall[2].number_ref, 'num-1');
  assert.ok(calls.filter(([kind]) => kind === 'control').every(([, payload]) => payload.account_id === 42));
});

test('VoiceSession flushes every transcript turn during the live call', async () => {
  const transcripts = [];
  const client = {
    getContext: async () => ({ call_ref: 'call-live', account_id: 42, ai: { provider: 'gemini-live' } }),
    sendControl: async () => ({ status: 'ok' }),
    sendTranscript: async (payload) => { transcripts.push(payload); return { status: 'ok', accepted: payload.items.length }; }
  };

  const session = new VoiceSession({ client, callRef: 'call-live' });
  await session.bootstrap();
  session.recordCallerTranscript('алло', { final: true, at: 't1' });
  await session.transcriptFlushPromise;
  session.recordAiTranscript('слушаю вас', { final: true, at: 't2' });
  await session.transcriptFlushPromise;

  assert.equal(transcripts.length, 2);
  assert.deepEqual(transcripts.map(payload => payload.items[0].text), ['алло', 'слушаю вас']);
  assert.ok(transcripts.every(payload => payload.final === true));
});

test('VoiceSession enters safe fallback when context is unavailable', async () => {
  const controls = [];
  const client = {
    getContext: async () => { throw Object.assign(new Error('context unavailable'), { code: 'context_unavailable' }); },
    sendControl: async (payload) => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' })
  };

  const session = new VoiceSession({ client, callRef: 'call-fallback' });
  const context = await session.bootstrap();

  assert.equal(session.state, 'fallback');
  assert.equal(context.ai.provider, 'scripted-fallback');
  assert.equal(controls[0].action, 'session_failed');
  assert.equal(controls[0].metadata.reason, 'context_unavailable');
});

test('VoiceSession applies timeout_ms from Rails tool catalog', async () => {
  const callOptions = [];
  const controls = [];
  const client = {
    getContext: async () => ({
      call_ref: 'call-faq',
      ai: { provider: 'gemini-live' },
      tools: [{ name: 'faq_lookup', enabled: true, timeout_ms: 6_000 }]
    }),
    sendControl: async (payload) => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async (_name, _payload, options) => { callOptions.push(options); return { matches: [] }; }
  };

  const session = new VoiceSession({ client, callRef: 'call-faq', toolTimeoutMs: 3_000 });
  await session.bootstrap();
  const result = await session.executeTool('faq_lookup', { query: 'refund' });

  assert.equal(result.ok, true);
  assert.equal(callOptions[0].timeoutMs, 6_000);
  assert.equal(controls.find(payload => payload.action === 'tool_started').metadata.timeout_ms, 6_000);
});
