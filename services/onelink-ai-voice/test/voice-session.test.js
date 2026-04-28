const test = require('node:test');
const assert = require('node:assert/strict');
const { VoiceSession } = require('../src/sessions/voice-session');

test('VoiceSession bootstraps Rails context, records lifecycle and flushes transcripts', async () => {
  const calls = [];
  const client = {
    getContext: async () => ({
      call_ref: 'call-1',
      ai: { provider: 'gemini-live', model: 'gemini-2.0-flash-live-001', first_message: 'Здравствуйте' },
      transfer: { enabled: true, operator_agent_aor: 'sip:1001@example.test' },
      tools: [{ name: 'request_transfer', enabled: true }]
    }),
    sendControl: async (payload) => { calls.push(['control', payload]); return { status: 'ok' }; },
    sendTranscript: async (payload) => { calls.push(['transcript', payload]); return { status: 'ok' }; },
    callTool: async (name) => ({ action: name === 'request_transfer' ? 'transfer' : 'noop', operator_agent_aor: 'sip:1001@example.test' })
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
  assert.equal(transcriptCall[1].items[0].text, 'Мне нужен оператор');
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
