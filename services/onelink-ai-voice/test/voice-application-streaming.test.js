const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { VoiceApplication } = require('../src/app/voice-application');

class FakeVoiceStream extends EventEmitter {
  constructor() {
    super();
    this.writes = [];
    this.closed = false;
    this.streamRef = 'stream-1';
    this.cleanupCallbacks = [];
  }

  onPayload(handler) {
    this.on('payload', handler);
  }

  emitPayload(payload) {
    this.emit('payload', payload);
  }

  write(payload) {
    this.writes.push(payload);
  }

  cleanup(handler) {
    this.cleanupCallbacks.push(handler);
  }

  close() {
    this.closed = true;
  }
}

test('VoiceApplication bridges Fonoster stream audio to Gemini realtime and writes model audio back to the call', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const transcripts = [];
  const realtimeAudio = [];
  const sentTexts = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    answerCount: 0,
    streamOptions: null,
    async answer() {
      this.answerCount += 1;
    },
    stream(options) {
      this.streamOptions = options;
      return stream;
    }
  });

  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'call-native-1',
      ai: { provider: 'gemini-live', model: 'gemini-live-test', first_message: 'Здравствуйте' },
      captain: { name: 'Кайрат Сатыбалды', system_prompt: 'Работай по инструкциям капитана.' },
      tools: [
        { name: 'lookup_customer', description: 'Lookup customer' },
        { name: 'faq_lookup', description: 'Search FAQ responses', parameters: { type: 'object', properties: {} } },
        { name: 'handoff', description: 'Hand off to human', parameters: { type: 'object', properties: {} } }
      ],
      transfer: { enabled: true }
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async payload => { transcripts.push(payload); return { status: 'ok' }; },
    callTool: async (name, payload) => ({ name, payload, ok: true })
  };

  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: (chunk, metadata) => realtimeAudio.push({ chunk, metadata }),
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime
  });

  const result = await app.handleCall(call, {
    call_ref: 'call-native-1',
    from: '+77001112233',
    to: '+77005556677'
  });

  assert.equal(result.mode, 'realtime');
  assert.equal(call.answerCount, 1);
  assert.equal(call.streamOptions.direction, 'both');
  assert.equal(call.streamOptions.format, 'wav');
  assert.equal(realtimeCallbacks.systemPrompt.includes('Здравствуйте'), true);
  assert.equal(realtimeCallbacks.systemPrompt.includes('Кайрат Сатыбалды'), true);
  assert.equal(realtimeCallbacks.systemPrompt.includes('Работай по инструкциям капитана.'), true);
  assert.equal(sentTexts.length, 1);
  assert.equal(sentTexts[0].includes('Здравствуйте'), true);
  assert.equal(sentTexts[0].includes('стартовую фразу'), true);
  assert.equal(realtimeCallbacks.tools[0].name, 'lookup_customer');
  const faqTool = realtimeCallbacks.tools.find(tool => tool.name === 'faq_lookup');
  assert.equal(faqTool.parameters.properties.query.type, 'string');
  assert.deepEqual(faqTool.parameters.required, ['query']);
  const handoffTool = realtimeCallbacks.tools.find(tool => tool.name === 'handoff');
  assert.equal(handoffTool.parameters.properties.reason.type, 'string');

  stream.emitPayload({ type: 'audio_in', data: Buffer.from([1, 2]), streamRef: 'stream-1', format: 'wav' });
  assert.deepEqual(realtimeAudio[0].chunk, Buffer.from([1, 2]));
  assert.equal(realtimeAudio[0].metadata.mimeType, 'audio/pcm;rate=16000');

  const geminiPcm24 = Buffer.alloc(960);
  for (let index = 0; index < 480; index += 1) geminiPcm24.writeInt16LE(index, index * 2);
  realtimeCallbacks.onAudio(geminiPcm24, { mimeType: 'audio/pcm;rate=24000' });
  assert.equal(stream.writes[0].type, 'audio_out');
  assert.equal(stream.writes[0].data.length, 320);
  assert.equal(stream.writes[0].data.readInt16LE(0), 0);
  assert.equal(stream.writes[0].data.readInt16LE(2), 3);
  assert.equal(stream.writes[0].streamRef, 'stream-1');
  assert.equal(stream.writes[0].mimeType, undefined);

  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'нужен оператор', final: true });
  await result.session.flushTranscript({ final: true });
  assert.equal(transcripts[0].items[0].text, 'нужен оператор');

  const toolResult = await realtimeCallbacks.onToolCall({ name: 'lookup_customer', args: { phone: '+77001112233' } });
  assert.equal(toolResult.ok, true);

  await realtimeCallbacks.onInterrupt();
  assert.equal(controls.at(-1).action, 'caller_interrupted');
  assert.equal(stream.cleanupCallbacks.length, 1);

  let completed = false;
  result.completion.then(() => { completed = true; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(completed, false);
  call.emit('end');
  await result.completion;
  assert.equal(completed, true);
});

test('VoiceApplication passes configured tool timeout into realtime tool execution', async () => {
  const controls = [];
  let realtimeCallbacks;
  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return new FakeVoiceStream(); }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'call-tool-timeout',
      ai: { provider: 'gemini-live' },
      tools: [{ name: 'slow_tool', description: 'Slow tool', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => new Promise(resolve => setTimeout(() => resolve({ ok: true }), 50))
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime, toolTimeoutMs: 10 });
  const result = await app.handleCall(call, { call_ref: 'call-tool-timeout' });

  const toolResult = await realtimeCallbacks.onToolCall({ name: 'slow_tool', args: {} });
  assert.equal(toolResult.ok, false);
  assert.equal(toolResult.error.includes('10ms'), true);
  assert.equal(controls.some(payload => payload.action === 'tool_failed'), true);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication executes AI transfer tools and finalizes the call as transferred', async () => {
  const stream = new FakeVoiceStream();
  const dialLeg = new EventEmitter();
  const controls = [];
  const events = [];
  const finalizations = [];
  const dialCalls = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; },
    async dial(target) {
      dialCalls.push(target);
      return dialLeg;
    }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', account_id: 42, number_ref: 'num-1' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'call-ai-transfer',
      account_id: 42,
      number_ref: 'num-1',
      conversation_id: 77,
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'request_transfer', description: 'Transfer to operator' }]
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizations.push(payload); return { status: 'ok' }; },
    callTool: async () => ({
      action: 'transfer',
      operator_agent_aor: 'sip:1001@example.test',
      reason: 'caller_requested_operator'
    })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime });
  const result = await app.handleCall(call, { call_ref: 'call-ai-transfer' });

  const toolResult = await realtimeCallbacks.onToolCall({ id: 'tool-transfer-1', name: 'request_transfer', args: { reason: 'caller_requested_operator' } });
  assert.equal(toolResult.result.action, 'transfer');
  assert.equal(dialCalls[0].agent_aor, 'sip:1001@example.test');
  assert.equal(events.some(payload => payload.event_type === 'transfer_requested'), true);

  dialLeg.emit('answered');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(controls.some(payload => payload.action === 'transfer_answered'), true);
  assert.equal(events.some(payload => payload.event_type === 'transfer_result' && payload.payload.result === 'answered'), true);

  call.emit('end');
  await result.completion;

  assert.equal(finalizations.at(-1).status, 'transferred');
  assert.equal(finalizations.at(-1).transfer_result.result, 'answered');
});

test('VoiceApplication paces model audio into 20ms frames and keeps buffered output on caller interruption by default', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'call-pacer-1', ai: { provider: 'gemini-live' } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime });
  const result = await app.handleCall(call, { call_ref: 'call-pacer-1' });

  const geminiPcm24 = Buffer.alloc(1920);
  for (let index = 0; index < 960; index += 1) geminiPcm24.writeInt16LE(index, index * 2);
  realtimeCallbacks.onAudio(geminiPcm24, { mimeType: 'audio/pcm;rate=24000' });

  assert.equal(stream.writes.length, 1);
  assert.equal(stream.writes[0].data.length, 320);
  assert.equal(stream.writes[0].data.readInt16LE(2), 3);

  await realtimeCallbacks.onInterrupt();
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(controls.at(-1).action, 'caller_interrupted');
  assert.equal(stream.writes.length, 2);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication asks Rails for a route first and dials operator without AI bootstrap', async () => {
  const routeCalls = [];
  const bridgeEvents = [];
  const dialCalls = [];
  const client = {
    routeInbound: async payload => {
      routeCalls.push(payload);
      return { action: 'operator', agent_aor: 'sip:1001@example.test', reason: 'operator_route' };
    },
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => { throw new Error('AI context should not be loaded for operator routes'); }
  };
  const call = {
    answerCount: 0,
    async answer() { this.answerCount += 1; },
    async dial(target) { dialCalls.push(target); }
  };
  const app = new VoiceApplication({ client });

  const result = await app.handleCall(call, {
    call_ref: 'call-operator-1',
    from: '+15557654321',
    to: '+15551234567',
    number_ref: 'number-1',
    app_ref: 'runtime-app-1'
  });

  assert.equal(result.mode, 'operator');
  assert.equal(call.answerCount, 1);
  assert.equal(routeCalls.length, 1);
  assert.equal(routeCalls[0].call_ref, 'call-operator-1');
  assert.equal(routeCalls[0].app_ref, 'runtime-app-1');
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'operator_ringing']);
  assert.equal(dialCalls[0].agent_aor, 'sip:1001@example.test');
  await result.completion;
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'operator_ringing']);
});

test('VoiceApplication falls back to an app when the operator leg reports no answer', async () => {
  const bridgeEvents = [];
  const handoffs = [];
  const dialLeg = new EventEmitter();
  const client = {
    routeInbound: async () => ({
      action: 'operator',
      agent_aor: 'sip:1001@example.test',
      fallback_mode: 'app',
      fallback_app_ref: 'fallback-app-1',
      operator_timeout_ms: 1000,
      reason: 'operator_route'
    }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => { throw new Error('AI context should not be loaded for operator routes'); }
  };
  const call = Object.assign(new EventEmitter(), {
    answerCount: 0,
    async answer() { this.answerCount += 1; },
    async dial() { return dialLeg; },
    async transferToApp(target) { handoffs.push(target); return true; }
  });
  const app = new VoiceApplication({ client });

  const result = await app.handleCall(call, { call_ref: 'call-operator-no-answer' });
  dialLeg.emit('no_answer');
  await result.completion;

  assert.equal(result.mode, 'operator');
  assert.equal(call.answerCount, 1);
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'operator_ringing', 'operator_no_answer', 'app_routing']);
  assert.equal(handoffs[0].app_ref, 'fallback-app-1');
  assert.equal(bridgeEvents.at(-1).metadata.operator_failure_event, 'operator_no_answer');
});

test('VoiceApplication emits caller_hangup when the caller disconnects before operator answer', async () => {
  const bridgeEvents = [];
  const dialLeg = new EventEmitter();
  const client = {
    routeInbound: async () => ({
      action: 'operator',
      agent_aor: 'sip:1001@example.test',
      operator_timeout_ms: 1000,
      reason: 'operator_route'
    }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => { throw new Error('AI context should not be loaded for operator routes'); }
  };
  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    async dial() { return dialLeg; }
  });
  const app = new VoiceApplication({ client });

  const result = await app.handleCall(call, { call_ref: 'call-operator-caller-hangup' });
  call.emit('end');
  await result.completion;

  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'operator_ringing', 'caller_hangup']);
});

test('VoiceApplication falls back when the operator dial leg ends before answer', async () => {
  const bridgeEvents = [];
  const handoffs = [];
  const dialLeg = new EventEmitter();
  const client = {
    routeInbound: async () => ({
      action: 'operator',
      agent_aor: 'sip:1001@example.test',
      fallback_mode: 'app',
      fallback_app_ref: 'fallback-app-1',
      operator_timeout_ms: 1000,
      reason: 'operator_route'
    }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => { throw new Error('AI context should not be loaded for operator routes'); }
  };
  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    async dial() { return dialLeg; },
    async transferToApp(target) { handoffs.push(target); return true; }
  });
  const app = new VoiceApplication({ client });

  const result = await app.handleCall(call, { call_ref: 'call-operator-leg-ended-before-answer' });
  dialLeg.emit('end');
  await result.completion;

  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'operator_ringing', 'operator_no_answer', 'app_routing']);
  assert.equal(handoffs[0].app_ref, 'fallback-app-1');
  assert.equal(bridgeEvents.at(2).metadata.reason, 'end');
});

test('VoiceApplication records terminal failure when operator fallback transfer fails', async () => {
  const bridgeEvents = [];
  const dialLeg = new EventEmitter();
  const client = {
    routeInbound: async () => ({
      action: 'operator',
      agent_aor: 'sip:1001@example.test',
      fallback_mode: 'app',
      fallback_app_ref: 'fallback-app-1',
      operator_timeout_ms: 1000,
      reason: 'operator_route'
    }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => { throw new Error('AI context should not be loaded for operator routes'); }
  };
  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    async dial() { return dialLeg; },
    async transferToApp() { throw new Error('fallback token=[REDACTED] failed'); },
    async reject() {}
  });
  const app = new VoiceApplication({ client });

  const result = await app.handleCall(call, { call_ref: 'call-operator-fallback-transfer-failed' });
  dialLeg.emit('no_answer');
  await result.completion;

  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'operator_ringing', 'operator_no_answer', 'app_routing', 'session_failed']);
  assert.match(bridgeEvents.at(-1).metadata.reason, /token=\[REDACTED\]/);
});

test('VoiceApplication emits a terminal event when the operator leg ends', async () => {
  const bridgeEvents = [];
  const dialLeg = new EventEmitter();
  const client = {
    routeInbound: async () => ({
      action: 'operator',
      agent_aor: 'sip:1001@example.test',
      operator_timeout_ms: 1000,
      reason: 'operator_route'
    }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => { throw new Error('AI context should not be loaded for operator routes'); }
  };
  const call = Object.assign(new EventEmitter(), {
    answerCount: 0,
    async answer() { this.answerCount += 1; },
    async dial() { return dialLeg; }
  });
  const app = new VoiceApplication({ client });

  const result = await app.handleCall(call, { call_ref: 'call-operator-ended' });
  dialLeg.emit('answered');
  await new Promise(resolve => setImmediate(resolve));
  call.emit('end');
  await result.completion;

  assert.equal(result.mode, 'operator');
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'operator_ringing', 'operator_answered', 'session_completed']);
});

test('VoiceApplication treats recursive AI app route decisions as local realtime sessions', async () => {
  const stream = new FakeVoiceStream();
  const bridgeEvents = [];
  let contextPayload;
  let realtimeCallbacks;
  const client = {
    routeInbound: async () => ({
      action: 'app',
      app_ref: 'fallback-runtime-app-1',
      reason: 'recursive_runtime_app_ref',
      account_id: 6,
      number_ref: 'number-ai-1'
    }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async payload => {
      contextPayload = payload;
      return {
        call_ref: payload.call_ref,
        account_id: payload.account_id,
        number_ref: payload.number_ref,
        ai: { provider: 'gemini-live', model: 'gemini-live-test', first_message: 'Здравствуйте' },
        tools: []
      };
    },
    sendControl: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' })
  };
  const call = Object.assign(new EventEmitter(), {
    answerCount: 0,
    async answer() { this.answerCount += 1; },
    stream: () => stream,
    async transferToApp() { throw new Error('recursive AI app should not be transferred again'); }
  });
  const app = new VoiceApplication({
    client,
    realtimeFactory: () => ({ connect: async options => { realtimeCallbacks = options; }, close: () => {} })
  });

  const result = await app.handleCall(call, {
    call_ref: 'call-recursive-ai-app',
    from: '+155****1001',
    to: '+155****7001',
    app_ref: 'ai-app-1'
  });

  assert.equal(result.mode, 'realtime');
  assert.equal(call.answerCount, 1);
  assert.equal(contextPayload.account_id, 6);
  assert.equal(contextPayload.number_ref, 'number-ai-1');
  assert.equal(realtimeCallbacks.systemPrompt.includes('Здравствуйте'), true);
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started']);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication hands app route decisions to the target app without AI bootstrap', async () => {
  const bridgeEvents = [];
  const handoffs = [];
  const client = {
    routeInbound: async () => ({ action: 'app', app_ref: 'target-app-1', reason: 'app_route' }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => { throw new Error('AI context should not be loaded for app routes'); }
  };
  const call = {
    answerCount: 0,
    async answer() { this.answerCount += 1; },
    async transferToApp(target) { handoffs.push(target); }
  };
  const app = new VoiceApplication({ client });

  const result = await app.handleCall(call, {
    call_ref: 'call-app-1',
    from: '+15554321001',
    to: '+15554567001',
    number_ref: 'number-1'
  });

  assert.equal(result.mode, 'app');
  assert.equal(call.answerCount, 1);
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'app_routing']);
  assert.equal(handoffs[0].app_ref, 'target-app-1');
});

test('VoiceApplication rejects the call safely when Rails route lookup fails', async () => {
  const bridgeEvents = [];
  const rejects = [];
  const client = {
    routeInbound: async () => { throw new Error('route token=super-secret unavailable'); },
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => { throw new Error('AI context should not be loaded when routing fails'); }
  };
  const call = {
    async reject(payload) { rejects.push(payload); }
  };
  const app = new VoiceApplication({ client });

  const result = await app.handleCall(call, {
    call_ref: 'call-route-failed',
    from: '+15554321002',
    to: '+15554567002'
  });

  assert.equal(result.mode, 'reject');
  assert.equal(result.decision.reason, 'route_lookup_failed');
  assert.equal(rejects.length, 1);
  assert.doesNotMatch(rejects[0].reason, /super-secret/);
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'session_failed']);
});

test('VoiceApplication falls back safely when realtime setup fails after context bootstrap', async () => {
  const controls = [];
  const greetings = [];
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'call-realtime-fail',
      ai: { provider: 'gemini-live', model: 'gemini-live-test', first_message: 'Здравствуйте' },
      tools: []
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' })
  };
  const app = new VoiceApplication({
    client,
    realtimeFactory: () => ({ connect: async () => { throw new Error('Gemini Live setup timeout'); }, close: () => {} }),
    fallbackResponder: { greet: async () => greetings.push('fallback') }
  });

  const fallbackCall = {
    answerCount: 0,
    async answer() { this.answerCount += 1; },
    stream: () => new FakeVoiceStream()
  };
  const result = await app.handleCall(fallbackCall, { call_ref: 'call-realtime-fail' });

  assert.equal(fallbackCall.answerCount, 1);
  assert.equal(result.mode, 'fallback');
  assert.equal(greetings.length, 1);
  assert.equal(controls.at(-1).action, 'session_failed');
  assert.equal(controls.at(-1).metadata.reason, 'Gemini Live setup timeout');
});
