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
      tools: [{ name: 'lookup_customer', description: 'Lookup customer' }],
      transfer: { enabled: true }
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async payload => { transcripts.push(payload); return { status: 'ok' }; },
    callTool: async (name, payload) => ({ name, payload, ok: true })
  };

  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
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
  assert.equal(realtimeCallbacks.tools[0].name, 'lookup_customer');

  stream.emitPayload({ type: 'audio_in', data: Buffer.from([1, 2]), streamRef: 'stream-1', format: 'wav' });
  assert.deepEqual(realtimeAudio[0].chunk, Buffer.from([1, 2]));
  assert.equal(realtimeAudio[0].metadata.mimeType, 'audio/pcm;rate=16000');

  realtimeCallbacks.onAudio(Buffer.from([3, 4]), { mimeType: 'audio/pcm;rate=24000' });
  assert.equal(stream.writes[0].type, 'audio_out');
  assert.deepEqual(stream.writes[0].data, Buffer.from([3, 4]));
  assert.equal(stream.writes[0].streamRef, 'stream-1');

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
