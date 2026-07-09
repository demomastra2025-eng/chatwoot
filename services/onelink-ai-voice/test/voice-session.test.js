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
    ['ai_ringing', 'tool_started', 'tool_completed', 'session_completed']
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

test('VoiceSession continues with degraded realtime context when context is unavailable', async () => {
  const controls = [];
  const events = [];
  const client = {
    getContext: async () => { throw Object.assign(new Error('context unavailable'), { code: 'context_unavailable' }); },
    sendControl: async (payload) => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async (payload) => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' })
  };

  const session = new VoiceSession({ client, callRef: 'call-fallback', accountId: 42, numberRef: 'number-1' });
  const context = await session.bootstrap();

  assert.equal(session.state, 'active');
  assert.equal(context.account_id, 42);
  assert.equal(context.number_ref, 'number-1');
  assert.equal(context.ai.provider, 'gemini-live');
  assert.equal(context.ai.context_degraded, true);
  assert.equal(context.ai.reason, 'context_unavailable');
  assert.deepEqual(controls.map(payload => payload.action), ['ai_ringing']);
  assert.equal(controls.every(payload => payload.metadata.degraded === true), true);
  assert.equal(events.some(payload => payload.event_type === 'context_fetch_failed' && payload.payload.degraded === true), true);
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

test('VoiceSession suppresses duplicate realtime tool calls with identical arguments', async () => {
  const controls = [];
  let toolInvocations = 0;
  const client = {
    getContext: async () => ({
      call_ref: 'call-faq-loop',
      ai: { provider: 'gemini-live' },
      tools: [{ name: 'faq_lookup', enabled: true, timeout_ms: 6_000 }]
    }),
    sendControl: async (payload) => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => {
      toolInvocations += 1;
      return { action: 'captain_tool', tool_name: 'faq_lookup', result: '{"total_count":0,"matches":[]}' };
    }
  };

  const session = new VoiceSession({ client, callRef: 'call-faq-loop' });
  await session.bootstrap();

  await session.executeTool('faq_lookup', { query: 'слоган' }, { tool_call_id: 'call-1' });
  await session.executeTool('faq_lookup', { query: '  СЛОГАН ' }, { tool_call_id: 'call-2' });
  const suppressed = await session.executeTool('faq_lookup', { query: 'слоган' }, { tool_call_id: 'call-3' });

  assert.equal(toolInvocations, 2);
  assert.equal(suppressed.ok, true);
  assert.equal(suppressed.suppressed, true);
  assert.equal(suppressed.result.action, 'tool_suppressed');
  assert.equal(controls.filter(payload => payload.action === 'tool_started').length, 2);
  assert.equal(controls.filter(payload => payload.action === 'tool_suppressed').length, 1);
});

test('VoiceSession still allows corrected arguments and retries after failed tool calls', async () => {
  const controls = [];
  const toolPayloads = [];
  let failOnce = true;
  const client = {
    getContext: async () => ({
      call_ref: 'call-tool-retry',
      ai: { provider: 'gemini-live' },
      tools: [{ name: 'faq_lookup', enabled: true, timeout_ms: 6_000 }]
    }),
    sendControl: async (payload) => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async (_name, payload) => {
      toolPayloads.push(payload.arguments);
      if (failOnce) {
        failOnce = false;
        throw new Error('temporary faq outage');
      }
      return { action: 'captain_tool', tool_name: 'faq_lookup', result: '{"total_count":1,"matches":[]}' };
    }
  };

  const session = new VoiceSession({ client, callRef: 'call-tool-retry' });
  await session.bootstrap();

  const failed = await session.executeTool('faq_lookup', { query: 'слоган' }, { tool_call_id: 'retry-1' });
  const retry = await session.executeTool('faq_lookup', { query: 'слоган' }, { tool_call_id: 'retry-2' });
  const corrected = await session.executeTool('faq_lookup', { query: 'слоган компании' }, { tool_call_id: 'retry-3' });

  assert.equal(failed.ok, false);
  assert.equal(retry.ok, true);
  assert.equal(corrected.ok, true);
  assert.equal(toolPayloads.length, 3);
  assert.equal(controls.some(payload => payload.action === 'tool_suppressed'), false);
});

test('VoiceSession sends finalize once with stable correlation refs', async () => {
  const finalizes = [];
  const client = {
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizes.push(payload); return { status: 'ok' }; }
  };
  const session = new VoiceSession({ client, callRef: 'runtime-ref', bridgeCallRef: 'bridge-ref', accountId: 42 });
  session.mediaSessionRef = 'media-ref';
  session.streamRef = 'stream-ref';

  await session.safeFinalize('session_completed');
  await session.safeFinalize('session_completed');
  await session.close('provider_stream_closed');

  assert.equal(finalizes.length, 1);
  assert.equal(finalizes[0].event_id, 'finalize:runtime-ref:session_completed');
  assert.equal(finalizes[0].bridge_call_ref, 'bridge-ref');
  assert.equal(finalizes[0].runtime_call_ref, 'runtime-ref');
  assert.equal(finalizes[0].media_session_ref, 'media-ref');
  assert.equal(finalizes[0].stream_ref, 'stream-ref');
});

test('VoiceSession includes best-effort partial transcripts in finalize payload', async () => {
  const finalizes = [];
  const client = {
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizes.push(payload); return { status: 'ok' }; }
  };
  const session = new VoiceSession({ client, callRef: 'partial-runtime', accountId: 42 });

  session.recordCallerTranscript('Здравствуйте. Один раз два.', { final: false, at: 't1' });
  await session.transcriptFlushPromise;
  await session.safeFinalize('session_completed');

  assert.equal(finalizes.length, 1);
  assert.equal(finalizes[0].incomplete_transcript, true);
  assert.deepEqual(finalizes[0].final_transcript.map(item => [item.speaker, item.text, item.final]), [
    ['caller', 'Здравствуйте. Один раз два.', true]
  ]);
  assert.equal(finalizes[0].final_transcript[0].normalized_from, 'partial_transcript_fallback');
  assert.deepEqual(finalizes[0].partial_transcript.map(item => item.text), ['Здравствуйте. Один раз два.']);
});

test('VoiceSession retries finalize after a transient client failure', async () => {
  const finalizes = [];
  let attempts = 0;
  const client = {
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => {
      attempts += 1;
      if (attempts === 1) throw new Error('temporary finalize outage');
      finalizes.push(payload);
      return { status: 'ok' };
    }
  };
  const session = new VoiceSession({ client, callRef: 'runtime-retry', bridgeCallRef: 'bridge-retry' });

  await session.safeFinalize('session_completed');
  await session.safeFinalize('session_completed');
  await session.safeFinalize('session_completed');

  assert.equal(attempts, 2);
  assert.equal(finalizes.length, 1);
  assert.equal(finalizes[0].bridge_call_ref, 'bridge-retry');
});

test('VoiceSession ignores non-terminal realtime work after close', async () => {
  const calls = [];
  const client = {
    sendControl: async payload => { calls.push(['control', payload]); return { status: 'ok' }; },
    sendEvent: async payload => { calls.push(['event', payload]); return { status: 'ok' }; },
    sendTranscript: async payload => { calls.push(['transcript', payload]); return { status: 'ok', accepted: payload.items.length }; },
    callTool: async (name, payload) => { calls.push(['tool', name, payload]); return { ok: true }; },
    finalizeCall: async payload => { calls.push(['finalize', payload]); return { status: 'ok' }; }
  };
  const session = new VoiceSession({ client, callRef: 'late-runtime', bridgeCallRef: 'late-bridge' });

  await session.close('session_completed');
  await session.safeEvent('realtime_audio_out', { bytes: 320 });
  await session.safeControl('tool_started', { tool_name: 'faq_lookup' });
  session.recordAiTranscript('late text', { final: true });
  await session.transcriptFlushPromise;
  const toolResult = await session.executeTool('faq_lookup', { query: 'late' });

  assert.equal(toolResult.ignored, true);
  assert.deepEqual(calls.filter(([kind]) => kind === 'event').map(([, payload]) => payload.event_type), []);
  assert.deepEqual(calls.filter(([kind]) => kind === 'control').map(([, payload]) => payload.action), ['session_completed']);
  assert.equal(calls.some(([kind]) => kind === 'transcript'), false);
  assert.equal(calls.some(([kind]) => kind === 'tool'), false);
});

test('VoiceSession does not double-persist control actions that Rails already stores as events', async () => {
  const calls = [];
  const client = {
    sendControl: async payload => { calls.push(['control', payload]); return { status: 'ok' }; },
    sendEvent: async payload => { calls.push(['event', payload]); return { status: 'ok' }; }
  };
  const session = new VoiceSession({ client, callRef: 'dedupe-runtime' });

  await session.safeControl('tool_completed', { tool_name: 'faq_lookup', tool_call_id: 'tool-1', ok: true });

  assert.deepEqual(calls.map(([kind]) => kind), ['control']);
});

test('VoiceSession falls back to direct event persistence when control acknowledgement fails', async () => {
  const calls = [];
  const client = {
    sendControl: async payload => { calls.push(['control', payload]); throw new Error('rails control down'); },
    sendEvent: async payload => { calls.push(['event', payload]); return { status: 'ok' }; }
  };
  const session = new VoiceSession({ client, callRef: 'control-fallback-runtime' });

  await session.safeControl('tool_completed', { tool_name: 'faq_lookup', tool_call_id: 'tool-1', ok: true });

  assert.deepEqual(calls.map(([kind]) => kind), ['control', 'event']);
  assert.equal(calls[1][1].event_type, 'tool_completed');
});
