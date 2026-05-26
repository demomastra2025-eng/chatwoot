const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { VoiceApplication } = require('../src/app/voice-application');
const { SessionRegistry } = require('../src/sessions/session-registry');

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
  const lifecycleOrder = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    answerCount: 0,
    streamOptions: null,
    async answer() {
      lifecycleOrder.push('answer');
      this.answerCount += 1;
    },
    stream(options) {
      lifecycleOrder.push('stream');
      this.streamOptions = options;
      return stream;
    }
  });

  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => {
      lifecycleOrder.push('context');
      return {
      call_ref: 'call-native-1',
      ai: { provider: 'gemini-live', model: 'gemini-live-test', first_message: 'Здравствуйте' },
      captain: { name: 'Кайрат Сатыбалды', system_prompt: 'Работай по инструкциям капитана.' },
      tools: [
        { name: 'lookup_customer', description: 'Lookup customer' },
        { name: 'faq_lookup', description: 'Search FAQ responses', parameters: { type: 'object', properties: {} } },
        { name: 'handoff', description: 'Hand off to human', parameters: { type: 'object', properties: {} } }
      ],
      transfer: { enabled: true }
      };
    },
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
  assert.deepEqual(lifecycleOrder.slice(0, 3), ['answer', 'stream', 'context']);
  assert.equal(call.streamOptions.direction, 'BOTH');
  assert.equal(call.streamOptions.format, 'WAV');
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
  assert.equal(stream.writes[0].type, 'AUDIO_OUT');
  assert.equal(stream.writes[0].data.length, 320);
  assert.equal(stream.writes[0].data.readInt16LE(0), 0);
  assert.equal(stream.writes[0].data.readInt16LE(2), 3);
  assert.equal(stream.writes[0].streamRef, 'stream-1');
  assert.equal(stream.writes[0].format, 'WAV');
  assert.equal(stream.writes[0].mimeType, undefined);

  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'нужен оператор', final: true });
  await result.session.flushTranscript({ final: true });
  assert.equal(transcripts[0].items[0].text, 'нужен оператор');

  const toolResult = await realtimeCallbacks.onToolCall({ name: 'lookup_customer', args: { phone: '+77001112233' } });
  assert.equal(toolResult.ok, true);

  const controlCountBeforeProviderInterrupt = controls.length;
  await realtimeCallbacks.onInterrupt({ source: 'serverContent.interrupted', reason: 'vad_or_caller_speech' });
  assert.equal(controls.length, controlCountBeforeProviderInterrupt);
  assert.equal(stream.cleanupCallbacks.length, 1);

  let completed = false;
  result.completion.then(() => { completed = true; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(completed, false);
  call.emit('end');
  await result.completion;
  assert.equal(completed, true);
  assert.equal(stream.closed, true);
});

test('VoiceApplication emits one caller_hangup bridge event when caller disconnects before realtime completion is registered', async () => {
  const stream = new FakeVoiceStream();
  const bridgeEvents = [];
  let releaseContext;
  const contextReady = new Promise(resolve => { releaseContext = resolve; });

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream: () => stream
  });

  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', account_id: 42, app_ref: 'ai-app-early' }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => {
      await contextReady;
      return {
        call_ref: 'call-early-hangup',
        account_id: 42,
        ai: { provider: 'gemini-live', model: 'gemini-live-test', first_message: 'Здравствуйте' },
        tools: []
      };
    },
    sendControl: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' })
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => ({
      connect: async () => {},
      sendText: () => {},
      sendAudio: () => {},
      close: () => {}
    })
  });

  const resultPromise = app.handleCall(call, {
    call_ref: 'call-early-hangup',
    from: '+770****2233',
    to: '+770****6677'
  });

  await new Promise(resolve => setImmediate(resolve));
  call.emit('disconnect');
  call.emit('close');
  call.emit('hangup');
  await new Promise(resolve => setImmediate(resolve));

  const callerHangups = bridgeEvents.filter(payload => payload.event === 'caller_hangup');
  assert.equal(callerHangups.length, 1);
  assert.equal(callerHangups[0].event_key, 'runtime:call-early-hangup:caller_hangup');
  assert.equal(callerHangups[0].call_ref, 'call-early-hangup');
  assert.equal(callerHangups[0].metadata.ended_by, 'caller');
  assert.equal(callerHangups[0].metadata.hangup_reason, 'caller_hangup');

  releaseContext();
  const result = await resultPromise;
  assert.equal(result.mode, 'caller_hangup');
  assert.equal(stream.closed, true);
});

test('VoiceApplication can send initial silence keepalive before Gemini emits first audio', async () => {
  const stream = new FakeVoiceStream();
  const events = [];
  let releaseContext;
  const contextReady = new Promise(resolve => { releaseContext = resolve; });
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream: () => stream
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => {
      await contextReady;
      return {
        call_ref: 'call-keepalive',
        ai: { provider: 'gemini-live', model: 'gemini-live-test', first_message: 'Здравствуйте' },
        tools: []
      };
    },
    sendControl: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; }
  };
  const app = new VoiceApplication({
    client,
    realtimeFactory: () => ({
      connect: async options => { realtimeCallbacks = options; },
      sendText: () => {},
      sendAudio: () => {},
      close: () => {}
    }),
    initialMediaKeepaliveMs: 1_000
  });

  const resultPromise = app.handleCall(call, { call_ref: 'call-keepalive' });
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(stream.writes.length > 0, true);
  assert.equal(stream.writes[0].type, 'AUDIO_OUT');
  assert.equal(stream.writes[0].streamRef, 'stream-1');
  assert.equal(stream.writes[0].data.length, 320);
  assert.equal(stream.writes[0].data.every(byte => byte === 0), true);

  releaseContext();
  const result = await resultPromise;
  const geminiPcm24 = Buffer.alloc(960);
  for (let index = 0; index < 480; index += 1) geminiPcm24.writeInt16LE(index, index * 2);
  realtimeCallbacks.onAudio(geminiPcm24, { mimeType: 'audio/pcm;rate=24000' });
  const modelAudioWrite = stream.writes.at(-1);
  assert.equal(modelAudioWrite.data.readInt16LE(2), 3);

  call.emit('end');
  await result.completion;
  assert.equal(events.some(payload => payload.event_type === 'media_keepalive_started'), true);
  assert.equal(events.some(payload => payload.event_type === 'media_keepalive_stopped'), true);
});

test('VoiceApplication emits first_audio_out_write telemetry from the managed Fonoster write callback', async () => {
  const stream = new FakeVoiceStream();
  const events = [];
  let managedOptions;
  const call = Object.assign(new EventEmitter(), {
    async answer() {}
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', app_ref: 'ai-app-1' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'call-first-audio-write',
      ai: { provider: 'gemini-live', model: 'gemini-live-test', first_message: 'Здравствуйте' },
      tools: []
    }),
    sendControl: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; }
  };
  const app = new VoiceApplication({
    client,
    managedStreamStarter: async (_call, options) => {
      managedOptions = options;
      return stream;
    },
    realtimeFactory: () => ({
      connect: async () => {},
      sendText: () => {},
      sendAudio: () => {},
      close: () => {}
    })
  });

  const result = await app.handleCall(call, { call_ref: 'call-first-audio-write', media_session_ref: 'media-first-audio-write' });
  managedOptions.onAudioOutWrite({
    first_audio_out_write_at: '2026-05-17T12:00:00.000Z',
    first_audio_out_write_bytes: 320,
    first_audio_out_write_kind: 'keepalive_silence',
    first_audio_out_non_zero_ratio: 0,
    first_audio_out_rms: 0,
    stream_ref: 'stream-1',
    media_session_ref: 'media-first-audio-write'
  });
  managedOptions.onAudioOutWrite({
    first_audio_out_write_at: '2026-05-17T12:00:00.020Z',
    first_audio_out_write_bytes: 320,
    first_audio_out_write_kind: 'model_audio',
    first_audio_out_non_zero_ratio: 0.5,
    first_audio_out_rms: 707,
    stream_ref: 'stream-1',
    media_session_ref: 'media-first-audio-write'
  });
  await new Promise(resolve => setImmediate(resolve));

  const telemetryEvents = events.filter(payload => payload.event_type === 'first_audio_out_write');
  assert.equal(telemetryEvents.length, 1);
  assert.equal(telemetryEvents[0].payload.first_audio_out_write_kind, 'keepalive_silence');
  assert.equal(telemetryEvents[0].payload.first_audio_out_write_bytes, 320);
  assert.equal(telemetryEvents[0].payload.first_audio_out_non_zero_ratio, 0);
  assert.equal(telemetryEvents[0].payload.stream_ref, 'stream-1');
  assert.equal(telemetryEvents[0].payload.media_session_ref, 'media-first-audio-write');

  call.emit('end');
  await result.completion;
});

test('VoiceApplication keeps OneLink recording writer anchored in the realtime media path when enabled', async () => {
  const stream = new FakeVoiceStream();
  let realtimeCallbacks;
  const writes = [];
  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream: () => stream
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'call-recording-path',
      account_id: 42,
      number_ref: 'num-42',
      recording: { enabled: true },
      ai: { provider: 'gemini-live', first_message: 'Здравствуйте' },
      tools: []
    }),
    sendControl: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' })
  };
  const recordingWriter = {
    start: async metadata => { writes.push(['start', metadata]); return true; },
    writeInbound: async (chunk, metadata) => { writes.push(['inbound', Buffer.from(chunk), metadata]); return true; },
    writeOutbound: async (chunk, metadata) => { writes.push(['outbound', Buffer.from(chunk), metadata]); return true; },
    close: async () => { writes.push(['close']); return {}; }
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => ({
      connect: async options => { realtimeCallbacks = options; },
      sendText: () => {},
      sendAudio: () => {},
      close: () => {}
    }),
    recordingWriterFactory: options => {
      assert.equal(options.callRef, 'call-recording-path');
      assert.equal(options.accountId, 42);
      assert.equal(options.numberRef, 'num-42');
      return recordingWriter;
    }
  });

  const result = await app.handleCall(call, { call_ref: 'call-recording-path' });
  stream.emitPayload({ type: 'audio_in', data: Buffer.from([1, 2]), streamRef: 'stream-1' });
  const geminiPcm24 = Buffer.alloc(960);
  realtimeCallbacks.onAudio(geminiPcm24, { mimeType: 'audio/pcm;rate=24000' });
  call.emit('end');
  await result.completion;

  assert.deepEqual(writes.map(([kind]) => kind), ['start', 'inbound', 'outbound', 'close']);
  assert.equal(writes[0][1].sampleRate, 16000);
  assert.equal(writes[2][2].source, 'realtime_model_audio');
  assert.equal(writes[2][2].source_rate, 24000);
  assert.equal(writes[2][2].recording_sample_rate, 16000);
  assert.equal(writes[2][1].length, 640);
});

test('VoiceApplication marks recording incomplete without failing media when recording writes fail', async () => {
  const stream = new FakeVoiceStream();
  let realtimeCallbacks;
  const events = [];
  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream: () => stream
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'call-recording-degraded',
      account_id: 42,
      recording: { enabled: true },
      ai: { provider: 'gemini-live', first_message: 'Здравствуйте' },
      tools: []
    }),
    sendControl: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; }
  };
  const app = new VoiceApplication({
    client,
    realtimeFactory: () => ({
      connect: async options => { realtimeCallbacks = options; },
      sendText: () => {},
      sendAudio: () => {},
      close: () => {}
    }),
    recordingWriterFactory: () => ({
      start: async () => true,
      writeInbound: () => { throw new Error('disk unavailable'); },
      writeOutbound: async () => true,
      close: async () => ({})
    })
  });

  const result = await app.handleCall(call, { call_ref: 'call-recording-degraded' });
  stream.emitPayload({ type: 'audio_in', data: Buffer.from([1, 2]), streamRef: 'stream-degraded' });
  await new Promise(resolve => setImmediate(resolve));
  const degradedEvent = events.find(payload => payload.event_type === 'recording_incomplete');
  assert.equal(degradedEvent.payload.recording_status, 'incomplete');
  assert.equal(degradedEvent.payload.degraded, true);
  assert.equal(degradedEvent.payload.missing_direction, 'caller');

  realtimeCallbacks.onAudio(Buffer.alloc(960), { mimeType: 'audio/pcm;rate=24000' });
  assert.equal(stream.writes.length, 1);
  call.emit('end');
  await result.completion;
});

test('VoiceApplication passively records operator-routed calls through the OneLink media path', async () => {
  const stream = new FakeVoiceStream();
  const dialLeg = new EventEmitter();
  const writes = [];
  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    async dial() { return dialLeg; }
  });
  const client = {
    routeInbound: async () => ({
      action: 'operator',
      reason: 'operator_route',
      account_id: 42,
      number_ref: 'num-42',
      agent_aor: 'sip:1001@example.test',
      recording: { enabled: true }
    }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' })
  };
  const recordingWriter = {
    start: async metadata => { writes.push(['start', metadata]); return true; },
    writeInbound: async chunk => { writes.push(['inbound', Buffer.from(chunk)]); return true; },
    writeOutbound: async chunk => { writes.push(['outbound', Buffer.from(chunk)]); return true; },
    close: async () => { writes.push(['close']); return {}; }
  };

  const app = new VoiceApplication({
    client,
    managedStreamStarter: async () => stream,
    recordingWriterFactory: () => recordingWriter
  });

  const result = await app.handleCall(call, { call_ref: 'operator-recording-call' });
  assert.equal(result.mode, 'operator');
  stream.emitPayload({ type: 'audio_in', data: Buffer.from([1, 2]), streamRef: 'stream-operator' });
  stream.emitPayload({ type: 'audio_out', data: Buffer.from([3, 4]), streamRef: 'stream-operator' });
  dialLeg.emit('answered');
  dialLeg.emit('end');
  await result.completion;

  assert.deepEqual(writes.map(([kind]) => kind), ['start', 'inbound', 'outbound', 'close']);
});

test('VoiceApplication passively records app-routed calls until the provider call ends', async () => {
  const stream = new FakeVoiceStream();
  const writes = [];
  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    async run() {}
  });
  const client = {
    routeInbound: async () => ({
      action: 'app',
      reason: 'app_route',
      app_ref: 'business-app-ref',
      account_id: 42,
      number_ref: 'num-42',
      recording: { enabled: true }
    }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' })
  };
  const recordingWriter = {
    start: async metadata => { writes.push(['start', metadata]); return true; },
    writeInbound: async chunk => { writes.push(['inbound', Buffer.from(chunk)]); return true; },
    writeOutbound: async chunk => { writes.push(['outbound', Buffer.from(chunk)]); return true; },
    close: async () => { writes.push(['close']); return {}; }
  };

  const app = new VoiceApplication({
    client,
    managedStreamStarter: async () => stream,
    recordingWriterFactory: () => recordingWriter
  });

  const result = await app.handleCall(call, { call_ref: 'app-recording-call' });
  assert.equal(result.mode, 'app');
  stream.emitPayload({ type: 'audio_in', data: Buffer.from([1, 2]), streamRef: 'stream-app' });
  stream.emitPayload({ type: 'audio_out', data: Buffer.from([3, 4]), streamRef: 'stream-app' });
  call.emit('end');
  await result.completion;

  assert.deepEqual(writes.map(([kind]) => kind), ['start', 'inbound', 'outbound', 'close']);
});

test('VoiceApplication can establish native managed media when provider call object has no call.stream helper', async () => {
  const stream = new FakeVoiceStream();
  const starterCalls = [];
  let realtimeCallbacks;
  const call = Object.assign(new EventEmitter(), {
    request: { callRef: 'runtime-native-only', mediaSessionRef: 'media-native-only' },
    voice: new EventEmitter(),
    async answer() {}
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', bridge_call_ref: 'bridge-native-only' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'runtime-native-only', ai: { provider: 'gemini-live', first_message: 'Здравствуйте' }, tools: [] }),
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' })
  };
  const app = new VoiceApplication({
    client,
    managedStreamStarter: async (providerCall, options) => {
      starterCalls.push({ providerCall, options });
      return stream;
    },
    realtimeFactory: () => ({ connect: async options => { realtimeCallbacks = options; }, sendAudio: () => {}, close: () => {} })
  });

  const result = await app.handleCall(call, { call_ref: 'runtime-native-only' });

  assert.equal(result.mode, 'realtime');
  assert.equal(starterCalls[0].providerCall, call);
  assert.equal(starterCalls[0].options.direction, 'BOTH');
  assert.equal(realtimeCallbacks.systemPrompt.length > 0, true);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication treats media stream close as an incomplete failure and preserves partial transcript', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const events = [];
  const finalizations = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', bridge_call_ref: 'bridge-media-closed' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'call-media-closed', ai: { provider: 'gemini-live' } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizations.push(payload); return { status: 'ok' }; }
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime });
  const result = await app.handleCall(call, { call_ref: 'call-media-closed' });
  realtimeCallbacks.onTranscript({ speaker: 'ai', text: 'Хотите', final: false });

  stream.emit('close');
  await result.completion;

  assert.equal(controls.at(-1).action, 'media_stream_closed');
  assert.equal(finalizations.at(-1).status, 'failed');
  assert.equal(finalizations.at(-1).reason, 'media_stream_closed');
  assert.equal(finalizations.at(-1).incomplete_transcript, true);
  assert.equal(finalizations.at(-1).bridge_call_ref, 'bridge-media-closed');
  assert.equal(finalizations.at(-1).final_transcript[0].text, 'Хотите');
  assert.equal(finalizations.at(-1).partial_transcript[0].text, 'Хотите');
  assert.equal(events.some(event => event.event_type === 'app_received_call'), true);
  assert.equal(events.find(event => event.event_type === 'app_received_call').payload.bridge_call_ref, 'bridge-media-closed');
  assert.equal(events.some(event => event.event_type === 'app_answered'), true);
  assert.equal(events.some(event => event.event_type === 'media_stream_started'), true);
  assert.equal(events.some(event => event.event_type === 'call_ended' && event.payload.reason === 'media_stream_closed'), true);
  assert.equal(controls.some(payload => payload.action === 'session_completed'), false);
});

test('VoiceApplication treats media stream close after live audio as completed', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const events = [];
  const finalizations = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', bridge_call_ref: 'bridge-media-after-audio' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'call-media-after-audio', ai: { provider: 'gemini-live' } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizations.push(payload); return { status: 'ok' }; }
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime });
  const result = await app.handleCall(call, { call_ref: 'call-media-after-audio' });
  realtimeCallbacks.onAudio(Buffer.alloc(960 * 3), { mimeType: 'audio/pcm;rate=24000' });
  assert.equal(stream.writes.length, 1);
  stream.emit('close');
  await result.completion;

  assert.equal(stream.writes.length, 3);
  assert.equal(controls.at(-1).action, 'session_completed');
  assert.equal(finalizations.at(-1).status, 'completed');
  assert.equal(finalizations.at(-1).reason, 'media_stream_closed');
  assert.equal(finalizations.at(-1).incomplete_transcript, undefined);
  assert.equal(finalizations.at(-1).media_stream_closed_after_audio, true);
  assert.ok(finalizations.at(-1).last_ai_audio_at);
  assert.ok(finalizations.at(-1).last_media_write_at);
  assert.equal(events.some(event => event.event_type === 'call_ended' && event.payload.final_status === 'completed'), true);
});

test('VoiceApplication classifies media writer byte errors as framing failures', async () => {
  const stream = new FakeVoiceStream();
  stream.write = () => {
    throw new Error('Read wrong number of bytes (478/1121) for payload');
  };
  const controls = [];
  const events = [];
  const finalizations = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', bridge_call_ref: 'bridge-framing-error' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'call-framing-error', ai: { provider: 'gemini-live' } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizations.push(payload); return { status: 'ok' }; }
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime });
  const result = await app.handleCall(call, { call_ref: 'call-framing-error' });
  const geminiPcm24 = Buffer.alloc(960);
  realtimeCallbacks.onAudio(geminiPcm24, { mimeType: 'audio/pcm;rate=24000' });

  await result.completion;

  assert.equal(controls.at(-1).action, 'media_stream_framing_error');
  assert.equal(finalizations.at(-1).status, 'failed');
  assert.equal(finalizations.at(-1).reason, 'media_stream_framing_error');
  assert.equal(events.some(event => event.event_type === 'media_stream_framing_error'), true);
  const framingEvent = events.find(event => event.event_type === 'media_stream_framing_error');
  assert.equal(framingEvent.payload.expected_frame_bytes, 320);
  assert.equal(framingEvent.payload.output_encoding, 'pcm_s16le');
  assert.equal(framingEvent.payload.error_message, 'Read wrong number of bytes (478/1121) for payload');
});

test('VoiceApplication fails explicitly when app leg answers but media stream is not established', async () => {
  const controls = [];
  const events = [];
  const finalizations = [];
  const hangups = [];

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return null; },
    async hangup(payload) { hangups.push(payload); }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', account_id: 42, number_ref: 'number-1', conversation_id: 77 }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'call-no-media', account_id: 42, number_ref: 'number-1', conversation_id: 77, ai: { provider: 'gemini-live' } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizations.push(payload); return { status: 'ok' }; }
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => { throw new Error('realtime should not start without media'); } });
  const result = await app.handleCall(call, { call_ref: 'call-no-media', number_ref: 'number-1' });

  assert.equal(result.mode, 'failed');
  assert.equal(result.reason, 'media_stream_not_established');
  assert.equal(controls.at(-1).action, 'media_stream_not_established');
  assert.equal(finalizations.at(-1).status, 'failed');
  assert.equal(finalizations.at(-1).reason, 'media_stream_not_established');
  assert.equal(finalizations.at(-1).incomplete_transcript, true);
  assert.equal(finalizations.at(-1).conversation_id, 77);
  assert.equal(finalizations.at(-1).ai_runtime_call_ref, 'call-no-media');
  assert.equal(events.some(event => event.event_type === 'media_stream_not_established'), true);
  assert.deepEqual(hangups, [{ reason: 'media_stream_not_established' }]);
});

test('VoiceApplication fails and removes the session when app answer never resolves', async () => {
  const events = [];
  const finalizations = [];
  const hangups = [];
  let streamCalled = false;
  const registry = new SessionRegistry();
  const call = Object.assign(new EventEmitter(), {
    answer() { return new Promise(() => {}); },
    stream() { streamCalled = true; return new FakeVoiceStream(); },
    async hangup(payload) { hangups.push(payload); }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', account_id: 42, number_ref: 'number-1', conversation_id: 77 }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => { throw new Error('context should not be fetched before answer'); },
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizations.push(payload); return { status: 'ok' }; }
  };

  const app = new VoiceApplication({
    client,
    registry,
    answerTimeoutMs: 1,
    realtimeFactory: () => { throw new Error('realtime should not start before answer'); }
  });
  const result = await app.handleCall(call, { call_ref: 'call-answer-timeout', number_ref: 'number-1' });

  assert.equal(result.mode, 'failed');
  assert.equal(result.reason, 'app_answer_timeout');
  assert.equal(streamCalled, false);
  assert.equal(events.some(event => event.event_type === 'app_answer_failed'), true);
  assert.equal(finalizations.at(-1).status, 'failed');
  assert.equal(finalizations.at(-1).reason, 'app_answer_timeout');
  assert.equal(finalizations.at(-1).ai_runtime_call_ref, 'call-answer-timeout');
  assert.deepEqual(hangups, [{ reason: 'app_answer_timeout' }]);
  assert.equal(registry.activeCount(), 0);
});

test('VoiceApplication closes the sidecar registry when context bootstrap falls back after media is established', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const registry = new SessionRegistry();
  const greetings = [];
  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', account_id: 42 }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => { throw new Error('request timed out after 5000ms'); },
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' })
  };

  const app = new VoiceApplication({
    client,
    registry,
    fallbackResponder: { greet: async () => greetings.push('fallback') },
    realtimeFactory: () => { throw new Error('realtime should not start without context'); }
  });

  const result = await app.handleCall(call, { call_ref: 'call-context-timeout', number_ref: 'number-1' });

  assert.equal(result.mode, 'fallback');
  assert.equal(stream.closed, true);
  assert.deepEqual(greetings, ['fallback']);
  assert.equal(controls.at(-1).action, 'session_failed');
  assert.equal(controls.at(-1).metadata.reason, 'request timed out after 5000ms');
  assert.equal(registry.activeCount(), 0);
});

test('VoiceApplication refuses to write AUDIO_OUT before a real streamRef exists', async () => {
  const stream = new FakeVoiceStream();
  stream.streamRef = '';
  stream.mediaSessionRef = 'media-no-stream-ref';
  const controls = [];
  const events = [];
  const finalizations = [];
  const hangups = [];

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; },
    async hangup(payload) { hangups.push(payload); }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', bridge_call_ref: 'bridge-no-stream-ref' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'call-no-stream-ref', ai: { provider: 'gemini-live', first_message: 'Здравствуйте' } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizations.push(payload); return { status: 'ok' }; }
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => { throw new Error('realtime should not start before streamRef is known'); }
  });
  const result = await app.handleCall(call, { call_ref: 'call-no-stream-ref', media_session_ref: 'media-no-stream-ref' });

  assert.equal(result.mode, 'failed');
  assert.equal(result.reason, 'media_stream_not_established');
  assert.equal(stream.closed, true);
  assert.equal(stream.writes.length, 0);
  assert.equal(controls.at(-1).action, 'media_stream_not_established');
  assert.equal(finalizations.at(-1).status, 'failed');
  assert.equal(finalizations.at(-1).reason, 'media_stream_not_established');
  assert.equal(finalizations.at(-1).stream_ref, undefined);
  const failureEvent = events.find(event => event.event_type === 'media_stream_not_established');
  assert.equal(failureEvent.payload.reason, 'media_stream_missing_stream_ref');
  assert.deepEqual(hangups, [{ reason: 'media_stream_not_established' }]);
});

test('VoiceApplication records StartStream response timeout as media-not-established diagnostic and closes the call', async () => {
  const controls = [];
  const events = [];
  const finalizations = [];
  const hangups = [];

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    async hangup(payload) { hangups.push(payload); }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', account_id: 42, number_ref: 'number-timeout', conversation_id: 88 }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'call-start-timeout', account_id: 42, number_ref: 'number-timeout', conversation_id: 88, ai: { provider: 'gemini-live' } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizations.push(payload); return { status: 'ok' }; }
  };
  const managedStreamStarter = async () => {
    const error = new Error('start_stream_response_timeout');
    error.reason = 'start_stream_response_timeout';
    error.source = 'fonoster_start_stream';
    error.timeoutMs = 7;
    throw error;
  };

  const app = new VoiceApplication({
    client,
    managedStreamStarter,
    realtimeFactory: () => { throw new Error('realtime should not start without media'); }
  });
  const result = await app.handleCall(call, { call_ref: 'call-start-timeout', number_ref: 'number-timeout' });

  assert.equal(result.mode, 'failed');
  assert.equal(result.reason, 'media_stream_not_established');
  assert.equal(controls.at(-1).action, 'media_stream_not_established');
  assert.equal(finalizations.at(-1).status, 'failed');
  assert.equal(finalizations.at(-1).reason, 'media_stream_not_established');
  const timeoutEvent = events.find(event => event.event_type === 'start_stream_response_timeout');
  assert.equal(timeoutEvent.payload.source, 'fonoster_start_stream');
  assert.equal(timeoutEvent.payload.timeout_ms, 7);
  const mediaFailureEvent = events.find(event => event.event_type === 'media_stream_not_established');
  assert.equal(mediaFailureEvent.payload.source, 'fonoster_start_stream');
  assert.deepEqual(hangups, [{ reason: 'media_stream_not_established' }]);
});

test('VoiceApplication records caller hangup without draining buffered output', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const finalizations = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'call-caller-hangup', ai: { provider: 'gemini-live' } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizations.push(payload); return { status: 'ok' }; }
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime });
  const result = await app.handleCall(call, { call_ref: 'call-caller-hangup' });
  const geminiPcm24 = Buffer.alloc(1920);
  realtimeCallbacks.onAudio(geminiPcm24, { mimeType: 'audio/pcm;rate=24000' });
  assert.equal(stream.writes.length, 1);

  call.emit('end');
  await result.completion;

  assert.equal(controls.at(-1).action, 'caller_hangup');
  assert.equal(finalizations.at(-1).status, 'caller_hung_up');
  assert.equal(finalizations.at(-1).reason, 'caller_hangup');
  assert.equal(stream.writes.length, 1);
});

test('VoiceApplication records provider websocket close as provider_stream_closed', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const events = [];
  const finalizations = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'call-provider-closed', ai: { provider: 'gemini-live' } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async payload => { finalizations.push(payload); return { status: 'ok' }; }
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime });
  const result = await app.handleCall(call, { call_ref: 'call-provider-closed' });

  realtimeCallbacks.onEvent({ close: { code: 1006, reason: 'abnormal close' } });
  await result.completion;

  assert.equal(controls.at(-1).action, 'provider_stream_closed');
  assert.equal(finalizations.at(-1).status, 'failed');
  assert.equal(finalizations.at(-1).reason, 'provider_stream_closed');
  assert.equal(finalizations.at(-1).close_code, 1006);
  assert.equal(events.some(event => event.event_type === 'provider_stream_closed'), true);
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
  assert.equal(toolResult.ok, true);
  assert.equal(toolResult.pending, true);
  assert.equal(toolResult.async, true);
  assert.equal(controls.some(payload => payload.action === 'tool_failed'), true);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication sends configured tool-wait fillers while a realtime tool is running', async () => {
  const sentTexts = [];
  const events = [];
  let realtimeCallbacks;
  let resolveTool;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return new FakeVoiceStream(); }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', bridge_call_ref: 'bridge-tool-wait' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-tool-wait',
      ai: {
        provider: 'gemini-live',
        tool_start_phrases: ['Секунду, проверю.'],
        tool_start_after_ms: 10,
        tool_delay_after_ms: 25,
        tool_delay_phrases: ['Ещё смотрю, почти готово.'],
        tool_prompt_min_interval_ms: 0
      },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async () => ({ status: 'ok' }),
    callTool: async () => new Promise(resolve => { resolveTool = resolve; })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime, toolTimeoutMs: 100 });
  const result = await app.handleCall(call, { call_ref: 'runtime-tool-wait' });

  const toolPromise = realtimeCallbacks.onToolCall({ id: 'tool-wait-1', name: 'faq_lookup', args: { query: 'режим' } });
  assert.equal(sentTexts.some(text => text.includes('Секунду, проверю.')), false);
  await new Promise(resolve => setTimeout(resolve, 15));
  assert.equal(sentTexts.some(text => text.includes('Секунду, проверю.')), true);
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(sentTexts.some(text => text.includes('Ещё смотрю, почти готово.')), true);

  resolveTool({ answer: 'Работаем до 18:00' });
  const toolResult = await toolPromise;
  assert.equal(toolResult.ok, true);
  assert.equal(events.some(event => event.event_type === 'dialogue_director_prompt' && event.payload.kind === 'tool_wait_start'), true);
  assert.equal(events.some(event => event.event_type === 'dialogue_director_prompt' && event.payload.kind === 'tool_wait_delay'), true);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication does not send tool-wait fillers for transfer tools', async () => {
  const sentTexts = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return new FakeVoiceStream(); },
    async dial() { return new EventEmitter(); }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-transfer-no-filler',
      ai: {
        provider: 'gemini-live',
        tool_start_phrases: ['Секунду, проверю.'],
        tool_delay_after_ms: 10,
        tool_delay_phrases: ['Ещё смотрю.']
      },
      tools: [{ name: 'request_transfer', description: 'Transfer to operator' }]
    }),
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    finalizeCall: async () => ({ status: 'ok' }),
    callTool: async () => ({ action: 'transfer', operator_agent_aor: 'sip:1001@example.test' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime });
  const result = await app.handleCall(call, { call_ref: 'runtime-transfer-no-filler' });
  await realtimeCallbacks.onToolCall({ id: 'transfer-1', name: 'request_transfer', args: {} });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(sentTexts.some(text => text.includes('Секунду, проверю.')), false);
  assert.equal(sentTexts.some(text => text.includes('Ещё смотрю.')), false);

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

test('VoiceApplication treats provider interruption as telemetry by default and preserves buffered output', async () => {
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

  const controlCountBeforeProviderInterrupt = controls.length;
  await realtimeCallbacks.onInterrupt({ source: 'serverContent.interrupted', reason: 'vad_or_caller_speech' });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(controls.length, controlCountBeforeProviderInterrupt);
  assert.equal(stream.writes.length > 1, true);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication honors per-assistant clear_audio_on_interrupt from context', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const interruptions = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({ call_ref: 'call-clear-on-interrupt', ai: { provider: 'gemini-live', clear_audio_on_interrupt: true } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    interrupt: () => interruptions.push('interrupt'),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime, clearOutputOnInterrupt: false });
  const result = await app.handleCall(call, { call_ref: 'call-clear-on-interrupt' });

  realtimeCallbacks.onAudio(Buffer.alloc(48000), { mimeType: 'audio/pcm;rate=24000' });
  assert.equal(stream.writes.length, 1);
  stream.emitPayload({ type: 'audio_in', data: Buffer.from([1, 2]), streamRef: 'stream-1', format: 'wav' });

  const controlCountBeforeProviderInterrupt = controls.length;
  await realtimeCallbacks.onInterrupt({ source: 'serverContent.interrupted', reason: 'vad_or_caller_speech' });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(controls.length, controlCountBeforeProviderInterrupt);
  assert.equal(stream.writes.length > 1, true);

  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'подо', final: false });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(controls.length, controlCountBeforeProviderInterrupt);

  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'подождите', final: true });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(controls.at(-1).action, 'caller_interrupted');
  assert.equal(controls.at(-1).metadata.source, 'caller_transcript_confirmed');
  assert.equal(controls.at(-1).metadata.clear_output_buffer, true);
  assert.equal(controls.at(-1).metadata.caller_transcript, 'подождите');
  assert.deepEqual(interruptions, ['interrupt']);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication clears queued audio on provider-mode interrupt after caller audio activity', async () => {
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
    getContext: async () => ({
      call_ref: 'call-provider-interrupt',
      ai: { provider: 'gemini-live', clear_audio_on_interrupt: true, interruption_mode: 'provider' }
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime, clearOutputOnInterrupt: false });
  const result = await app.handleCall(call, { call_ref: 'call-provider-interrupt' });

  realtimeCallbacks.onAudio(Buffer.alloc(1920), { mimeType: 'audio/pcm;rate=24000' });
  assert.equal(stream.writes.length, 1);
  stream.emitPayload({ type: 'audio_in', data: Buffer.from([1, 2]), streamRef: 'stream-1', format: 'wav' });

  await realtimeCallbacks.onInterrupt({ source: 'serverContent.interrupted', reason: 'vad_or_caller_speech' });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(controls.at(-1).action, 'caller_interrupted');
  assert.equal(controls.at(-1).metadata.clear_output_buffer, true);
  assert.equal(stream.writes.length, 1);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication does not emit user-facing interrupt without fresh caller activity', async () => {
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
    getContext: async () => ({ call_ref: 'call-no-fresh-interrupt', ai: { provider: 'gemini-live', clear_audio_on_interrupt: true } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime, clearOutputOnInterrupt: false });
  const result = await app.handleCall(call, { call_ref: 'call-no-fresh-interrupt' });

  realtimeCallbacks.onAudio(Buffer.alloc(1920), { mimeType: 'audio/pcm;rate=24000' });
  assert.equal(stream.writes.length, 1);

  const controlCountBeforeProviderInterrupt = controls.length;
  await realtimeCallbacks.onInterrupt({ source: 'serverContent.interrupted', reason: 'vad_or_caller_speech' });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(controls.length, controlCountBeforeProviderInterrupt);
  assert.equal(stream.writes.length > 1, true);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication preserves queued audio when provider interrupt follows stale caller transcript', async () => {
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
    getContext: async () => ({ call_ref: 'call-stale-interrupt', ai: { provider: 'gemini-live', clear_audio_on_interrupt: true } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime, clearOutputOnInterrupt: false });
  const result = await app.handleCall(call, { call_ref: 'call-stale-interrupt' });

  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'алло', final: true, at: '2026-05-20T04:15:13.999Z' });
  realtimeCallbacks.onAudio(Buffer.alloc(1920), { mimeType: 'audio/pcm;rate=24000' });
  assert.equal(stream.writes.length, 1);

  const controlCountBeforeProviderInterrupt = controls.length;
  await realtimeCallbacks.onInterrupt({ source: 'serverContent.interrupted', reason: 'vad_or_caller_speech' });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(controls.length, controlCountBeforeProviderInterrupt);
  assert.equal(stream.writes.length > 1, true);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication treats the next caller question after drained AI audio as a normal turn, not an interruption', async () => {
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
    getContext: async () => ({ call_ref: 'call-normal-next-turn', ai: { provider: 'gemini-live', clear_audio_on_interrupt: true } }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime, clearOutputOnInterrupt: false });
  const result = await app.handleCall(call, { call_ref: 'call-normal-next-turn' });

  realtimeCallbacks.onAudio(Buffer.alloc(960), { mimeType: 'audio/pcm;rate=24000' });
  await new Promise(resolve => setTimeout(resolve, 90));
  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'какой у вас слоган?', final: true });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(controls.some(payload => payload.action === 'caller_interrupted'), false);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication injects late async tool result back into Gemini context after foreground timeout', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const events = [];
  const sentTexts = [];
  const sentToolResponses = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-tool-late-result',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} }, timeout_ms: 200, foreground_wait_ms: 5 }]
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => new Promise(resolve => setTimeout(() => resolve({ answer: 'Акуна матата' }), 25))
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendToolResponse: (id, response, name) => sentToolResponses.push({ id, response, name }),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    toolTimeoutMs: 200,
    postToolContinuationMs: 100
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-tool-late-result' });

  const toolResult = await realtimeCallbacks.onToolCall({ id: 'tool-late-1', name: 'faq_lookup', args: { query: 'слоган' } });
  assert.equal(toolResult.ok, true);
  assert.equal(toolResult.pending, true);
  assert.equal(toolResult.request_id, 'tool-late-1');
  await new Promise(resolve => setTimeout(resolve, 50));

  assert.equal(controls.some(payload => payload.action === 'tool_async_completed'), true);
  assert.equal(sentToolResponses.length, 1);
  assert.equal(sentToolResponses[0].id, 'tool-late-1');
  assert.equal(sentToolResponses[0].name, 'faq_lookup');
  assert.deepEqual(sentToolResponses[0].response.result, { answer: 'Акуна матата' });
  assert.equal(sentTexts.some(text => text.includes('Результат инструмента faq_lookup готов')), true);
  assert.equal(sentTexts.some(text => text.includes('Акуна матата')), true);
  const injectedEvent = events.find(payload => payload.event_type === 'tool_async_result_injected');
  assert.equal(injectedEvent.payload.delivery_channel, 'tool_response_and_text');

  call.emit('end');
  await result.completion;
});

test('VoiceApplication injects late async tool failure back into Gemini context after foreground timeout', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const events = [];
  const sentTexts = [];
  const sentToolResponses = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-tool-late-failure',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} }, timeout_ms: 200, foreground_wait_ms: 5 }]
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => new Promise((_resolve, reject) => setTimeout(() => reject(new Error('rails unavailable')), 25))
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendToolResponse: (id, response, name) => sentToolResponses.push({ id, response, name }),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime, toolTimeoutMs: 200 });
  const result = await app.handleCall(call, { call_ref: 'runtime-tool-late-failure' });

  const toolResult = await realtimeCallbacks.onToolCall({ id: 'tool-late-fail-1', name: 'faq_lookup', args: { query: 'слоган' } });
  assert.equal(toolResult.ok, true);
  assert.equal(toolResult.pending, true);
  await new Promise(resolve => setTimeout(resolve, 50));

  assert.equal(controls.some(payload => payload.action === 'tool_async_failed'), true);
  assert.equal(sentToolResponses.length, 1);
  assert.equal(sentToolResponses[0].id, 'tool-late-fail-1');
  assert.equal(sentToolResponses[0].response.ok, false);
  assert.equal(sentToolResponses[0].response.error, 'rails unavailable');
  assert.equal(sentTexts.some(text => text.includes('Результат инструмента faq_lookup: ошибка')), true);
  const injectedEvent = events.find(payload => payload.event_type === 'tool_async_result_injected');
  assert.equal(injectedEvent.payload.ok, false);
  assert.equal(injectedEvent.payload.delivery_channel, 'tool_response_and_text');

  call.emit('end');
  await result.completion;
});

test('VoiceApplication floors read-tool foreground wait so normal Rails latency does not become a user-facing failure', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const sentTexts = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-tool-normal-latency',
      ai: { provider: 'gemini-live', model: 'gemini-live-test', tool_foreground_wait_ms: 5 },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} }, timeout_ms: 200 }]
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => new Promise(resolve => setTimeout(() => resolve({ answer: 'Акуна матата' }), 25))
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime, toolTimeoutMs: 200 });
  const result = await app.handleCall(call, { call_ref: 'runtime-tool-normal-latency' });

  const toolResult = await realtimeCallbacks.onToolCall({ id: 'tool-normal-1', name: 'faq_lookup', args: { query: 'слоган' } });

  assert.equal(toolResult.ok, true);
  assert.equal(toolResult.pending, undefined);
  assert.equal(controls.some(payload => payload.action === 'tool_failed'), false);
  assert.equal(controls.some(payload => payload.action === 'tool_async_completed'), false);
  assert.equal(sentTexts.some(text => text.includes('Результат инструмента faq_lookup готов')), false);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication does not apply global foreground timeout to unknown mutating tools', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const sentTexts = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-mutating-tool-waits',
      ai: { provider: 'gemini-live', model: 'gemini-live-test', tool_foreground_wait_ms: 5 },
      tools: [{ name: 'book_appointment', description: 'Book appointment', parameters: { type: 'object', properties: {} }, timeout_ms: 200 }]
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => new Promise(resolve => setTimeout(() => resolve({ appointment_id: 42 }), 25))
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({ client, realtimeFactory: () => realtime, toolTimeoutMs: 200 });
  const result = await app.handleCall(call, { call_ref: 'runtime-mutating-tool-waits' });

  const toolResult = await realtimeCallbacks.onToolCall({ id: 'tool-book-1', name: 'book_appointment', args: { slot: '10:00' } });
  await new Promise(resolve => setTimeout(resolve, 40));

  assert.equal(toolResult.ok, true);
  assert.equal(toolResult.pending, undefined);
  assert.equal(controls.some(payload => payload.action === 'tool_async_completed'), false);
  assert.equal(sentTexts.length, 0);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication sends a bounded Gemini continuation when the model stalls after a successful tool response', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const events = [];
  const sentTexts = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', bridge_call_ref: 'bridge-tool-stall' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-tool-stall',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => ({ action: 'captain_tool', result: '{"query":"слоган","total_count":0,"matches":[]}' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    postToolContinuationMs: 10
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-tool-stall' });

  const toolResult = await realtimeCallbacks.onToolCall({ id: 'tool-1', name: 'faq_lookup', args: { query: 'слоган' } });
  realtimeCallbacks.onEvent({ serverContent: { turnComplete: true } });
  assert.equal(toolResult.ok, true);
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(sentTexts.some(text => text.includes('Продолжи голосовой ответ')), true);
  assert.equal(sentTexts.some(text => text.includes('ничего не найдено')), true);
  const stallControl = controls.find(payload => payload.action === 'post_tool_model_stall');
  assert.ok(stallControl);
  assert.equal(stallControl.metadata.tool_name, 'faq_lookup');
  assert.equal(stallControl.metadata.bridge_call_ref, 'bridge-tool-stall');

  call.emit('end');
  await result.completion;
});

test('VoiceApplication cancels post-tool stall watchdog when Gemini continues with answer transcript', async () => {
  const stream = new FakeVoiceStream();
  const events = [];
  const sentTexts = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-tool-continues',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => ({ answer: 'Акуна матата' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    postToolContinuationMs: 30
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-tool-continues' });

  await realtimeCallbacks.onToolCall({ id: 'tool-1', name: 'faq_lookup', args: { query: 'слоган' } });
  realtimeCallbacks.onTranscript({ speaker: 'ai', text: 'Наш слоган — Акуна матата.', final: true });
  await new Promise(resolve => setTimeout(resolve, 50));

  assert.equal(sentTexts.some(text => text.includes('Продолжи голосовой ответ')), false);
  assert.equal(events.some(event => event.event_type === 'post_tool_model_stall'), false);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication nudges Gemini when a post-tool answer stops mid-sentence', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const sentTexts = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', bridge_call_ref: 'bridge-incomplete-answer' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-incomplete-answer',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'search_deals', description: 'Search CRM deals', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => ({ action: 'captain_tool', result: '{"deals":[{"title":"Тест","stage":"Спящие"}]}' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    incompleteAnswerContinuationMs: 10,
    postToolContinuationMs: 0
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-incomplete-answer' });

  await realtimeCallbacks.onToolCall({ id: 'tool-1', name: 'search_deals', args: { query: 'мои сделки' } });
  realtimeCallbacks.onTranscript({ speaker: 'ai', text: 'Я вижу, что у вас есть сделка в воронке Продажи на этапе', final: true });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(sentTexts.some(text => text.includes('Договори последнюю голосовую реплику')), true);
  const stallControl = controls.find(payload => payload.action === 'incomplete_answer_model_stall');
  assert.ok(stallControl);
  assert.equal(stallControl.metadata.last_ai_text.includes('на этапе'), true);
  assert.equal(stallControl.metadata.bridge_call_ref, 'bridge-incomplete-answer');

  call.emit('end');
  await result.completion;
});

test('VoiceApplication cancels post-tool stall watchdog when Gemini streams answer audio before transcript', async () => {
  const stream = new FakeVoiceStream();
  const events = [];
  const sentTexts = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-tool-audio-continues',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => ({ answer: 'Акуна матата' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    postToolContinuationMs: 30
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-tool-audio-continues' });

  await realtimeCallbacks.onToolCall({ id: 'tool-1', name: 'faq_lookup', args: { query: 'слоган' } });
  realtimeCallbacks.onAudio(Buffer.alloc(960), { mimeType: 'audio/pcm;rate=24000' });
  await new Promise(resolve => setTimeout(resolve, 50));

  assert.equal(stream.writes.length > 0, true);
  assert.equal(sentTexts.some(text => text.includes('Продолжи голосовой ответ')), false);
  assert.equal(events.some(event => event.event_type === 'post_tool_model_stall'), false);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication keeps post-tool continuation armed when only a tool-wait filler is spoken', async () => {
  const stream = new FakeVoiceStream();
  const events = [];
  const controls = [];
  const sentTexts = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', bridge_call_ref: 'bridge-tool-filler' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-tool-filler',
      ai: {
        provider: 'gemini-live',
        model: 'gemini-live-test',
        tool_start_phrases: ['Секунду, проверю.']
      },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async () => ({ answer: 'Акуна матата' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    postToolContinuationMs: 10
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-tool-filler' });

  await realtimeCallbacks.onToolCall({ id: 'tool-1', name: 'faq_lookup', args: { query: 'слоган' } });
  realtimeCallbacks.onTranscript({ speaker: 'ai', text: 'Секунду, проверю.', final: true });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(sentTexts.some(text => text.includes('Продолжи голосовой ответ')), true);
  assert.equal(controls.some(payload => payload.action === 'post_tool_model_stall'), true);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication deterministically runs faq_lookup for business questions when Gemini does not call a tool', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const events = [];
  const sentTexts = [];
  const toolCalls = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route', bridge_call_ref: 'bridge-business-faq' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-business-faq',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async (name, payload) => {
      toolCalls.push({ name, payload });
      return { answer: 'Наш слоган — Акуна матата.' };
    }
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    businessFaqGateDelayMs: 5,
    ordinaryAnswerContinuationMs: 0
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-business-faq' });

  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'Какой у вас слоган?', final: true });
  await new Promise(resolve => setTimeout(resolve, 30));

  assert.equal(toolCalls.length, 1);
  assert.equal(toolCalls[0].name, 'faq_lookup');
  assert.deepEqual(toolCalls[0].payload.arguments, { query: 'Какой у вас слоган?' });
  assert.equal(controls.some(payload => payload.action === 'business_faq_gate_fired'), true);
  assert.equal(controls.some(payload => payload.action === 'tool_started'), true);
  assert.equal(controls.some(payload => payload.action === 'tool_completed'), true);
  assert.equal(sentTexts.some(text => text.includes('Результат инструмента faq_lookup готов')), true);
  assert.equal(sentTexts.some(text => text.includes('Акуна матата')), true);
  assert.equal(events.some(event => event.event_type === 'business_faq_gate_result_injected'), true);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication cancels deterministic faq gate when Gemini calls a tool itself', async () => {
  const stream = new FakeVoiceStream();
  const sentTexts = [];
  const toolCalls = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-business-faq-cancel',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async (name, payload) => {
      toolCalls.push({ name, payload });
      return { answer: 'Наш слоган — Акуна матата.' };
    }
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    businessFaqGateDelayMs: 20,
    ordinaryAnswerContinuationMs: 0
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-business-faq-cancel' });

  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'Какой у вас слоган?', final: true });
  await realtimeCallbacks.onToolCall({ id: 'tool-model-1', name: 'faq_lookup', args: { query: 'слоган' } });
  await new Promise(resolve => setTimeout(resolve, 35));

  assert.equal(toolCalls.length, 1);
  assert.deepEqual(toolCalls[0].payload.arguments, { query: 'слоган' });
  assert.equal(sentTexts.filter(text => text.includes('Результат инструмента faq_lookup готов')).length, 0);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication reuses in-flight deterministic faq gate when Gemini calls faq_lookup late', async () => {
  const stream = new FakeVoiceStream();
  const toolCalls = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-business-faq-race',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async (name, payload) => {
      toolCalls.push({ name, payload });
      await new Promise(resolve => setTimeout(resolve, 25));
      return { answer: 'Наш слоган — Акуна матата.' };
    }
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: () => {},
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    businessFaqGateDelayMs: 5,
    ordinaryAnswerContinuationMs: 0
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-business-faq-race' });

  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'Какой у вас слоган?', final: true });
  await new Promise(resolve => setTimeout(resolve, 10));
  const toolResult = await realtimeCallbacks.onToolCall({ id: 'tool-model-late', name: 'faq_lookup', args: { query: 'слоган' } });

  assert.equal(toolResult.ok, true);
  assert.equal(toolCalls.length, 1);
  assert.deepEqual(toolCalls[0].payload.arguments, { query: 'Какой у вас слоган?' });

  call.emit('end');
  await result.completion;
});

test('VoiceApplication reuses completed deterministic faq gate when Gemini calls faq_lookup after completion', async () => {
  const stream = new FakeVoiceStream();
  const toolCalls = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-business-faq-completed-race',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: [{ name: 'faq_lookup', description: 'Search FAQ', parameters: { type: 'object', properties: {} } }]
    }),
    sendControl: async () => ({ status: 'ok' }),
    sendEvent: async () => ({ status: 'ok' }),
    sendTranscript: async () => ({ status: 'ok' }),
    callTool: async (name, payload) => {
      toolCalls.push({ name, payload });
      return { answer: 'Наш слоган — Акуна матата.' };
    }
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: () => {},
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    businessFaqGateDelayMs: 5,
    ordinaryAnswerContinuationMs: 0
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-business-faq-completed-race' });

  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'Какой у вас слоган?', final: true });
  await new Promise(resolve => setTimeout(resolve, 30));
  const toolResult = await realtimeCallbacks.onToolCall({ id: 'tool-model-after-gate', name: 'faq_lookup', args: { query: 'слоган' } });

  assert.equal(toolResult.ok, true);
  assert.equal(toolCalls.length, 1);
  assert.deepEqual(toolCalls[0].payload.arguments, { query: 'Какой у вас слоган?' });

  call.emit('end');
  await result.completion;
});

test('VoiceApplication nudges Gemini when a normal caller turn stalls without tool or answer', async () => {
  const stream = new FakeVoiceStream();
  const controls = [];
  const sentTexts = [];
  let realtimeCallbacks;

  const call = Object.assign(new EventEmitter(), {
    async answer() {},
    stream() { return stream; }
  });
  const client = {
    routeInbound: async () => ({ action: 'ai', reason: 'ai_route' }),
    sendBridgeEvent: async () => ({ status: 'ok' }),
    getContext: async () => ({
      call_ref: 'runtime-ordinary-stall',
      ai: { provider: 'gemini-live', model: 'gemini-live-test' },
      tools: []
    }),
    sendControl: async payload => { controls.push(payload); return { status: 'ok' }; },
    sendTranscript: async () => ({ status: 'ok' })
  };
  const realtime = {
    connect: async options => { realtimeCallbacks = options; },
    sendText: text => sentTexts.push(text),
    sendAudio: () => {},
    close: () => {}
  };

  const app = new VoiceApplication({
    client,
    realtimeFactory: () => realtime,
    ordinaryAnswerContinuationMs: 10
  });
  const result = await app.handleCall(call, { call_ref: 'runtime-ordinary-stall' });

  realtimeCallbacks.onTranscript({ speaker: 'caller', text: 'Расскажите подробнее про услугу', final: true });
  await new Promise(resolve => setTimeout(resolve, 25));

  assert.equal(controls.some(payload => payload.action === 'ordinary_answer_model_stall'), true);
  assert.equal(sentTexts.some(text => text.includes('Ответь клиенту сейчас')), true);

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
    from: '+155****4321',
    to: '+155****4567',
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

test('VoiceApplication fans out operator pool and records the first answered candidate', async () => {
  const bridgeEvents = [];
  const dialCalls = [];
  const loserHangups = [];
  const primaryLeg = Object.assign(new EventEmitter(), {
    hangup(payload) { loserHangups.push({ leg: 'primary', payload }); }
  });
  const secondaryLeg = Object.assign(new EventEmitter(), {
    hangup(payload) { loserHangups.push({ leg: 'secondary', payload }); }
  });
  const client = {
    routeInbound: async () => ({
      action: 'operator',
      reason: 'operator_route',
      operator_timeout_ms: 1000,
      operator_pool: true,
      operator_candidates: [
        { agent_ref: 'fonoster-agent-1', agent_aor: 'sip:1001@example.test', user_id: 11 },
        { agent_ref: 'fonoster-agent-2', agent_aor: 'sip:1002@example.test', user_id: 12 }
      ]
    }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => { throw new Error('AI context should not be loaded for operator routes'); }
  };
  const call = Object.assign(new EventEmitter(), {
    answerCount: 0,
    async answer() { this.answerCount += 1; },
    async dial(target) {
      dialCalls.push(target);
      return target.agent_aor === 'sip:1001@example.test' ? primaryLeg : secondaryLeg;
    }
  });
  const app = new VoiceApplication({ client });

  const result = await app.handleCall(call, { call_ref: 'call-operator-pool' });
  secondaryLeg.emit('answered');
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(result.mode, 'operator');
  assert.equal(call.answerCount, 1);
  assert.deepEqual(dialCalls.map(target => target.agent_aor), ['sip:1001@example.test', 'sip:1002@example.test']);
  const answeredEvent = bridgeEvents.find(event => event.event === 'operator_answered');
  assert.equal(answeredEvent.metadata.agent_ref, 'fonoster-agent-2');
  assert.equal(answeredEvent.metadata.user_id, 12);
  assert.deepEqual(answeredEvent.metadata.operator_candidate_agent_aors, ['sip:1001@example.test', 'sip:1002@example.test']);
  assert.deepEqual(loserHangups, [{ leg: 'primary', payload: { reason: 'answered_by_other_operator' } }]);

  primaryLeg.emit('end');
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'operator_ringing', 'operator_answered']);

  call.emit('end');
  await result.completion;
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'operator_ringing', 'operator_answered', 'session_completed']);
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

test('VoiceApplication keeps caller_hangup as the only terminal event when caller disconnects while operator dial is pending', async () => {
  const bridgeEvents = [];
  let releaseDial;
  const dialReady = new Promise(resolve => { releaseDial = resolve; });
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
    async dial() {
      await dialReady;
      return false;
    }
  });
  const app = new VoiceApplication({ client });

  const resultPromise = app.handleCall(call, { call_ref: 'call-operator-dial-pending-hangup' });
  await new Promise(resolve => setImmediate(resolve));
  call.emit('disconnect');
  releaseDial();

  const result = await resultPromise;
  assert.equal(result.mode, 'caller_hangup');
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
  const events = [];
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
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
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
  assert.equal(bridgeEvents[0].app_ref, 'ai-app-1');
  assert.equal(bridgeEvents[0].metadata.route_app_ref, 'fallback-runtime-app-1');
  assert.equal(bridgeEvents[0].metadata.topology, 'direct_ai');
  assert.equal(events.find(event => event.event_type === 'app_received_call').payload.app_ref, 'ai-app-1');
  assert.equal(events.find(event => event.event_type === 'call_started').payload.app_ref, 'ai-app-1');
  assert.equal(events.find(event => event.event_type === 'call_started').payload.route_app_ref, 'fallback-runtime-app-1');
  assert.equal(events.find(event => event.event_type === 'call_started').payload.topology, 'direct_ai');
  assert.equal(events.some(event => event.event_type === 'media_stream_established'), true);
  assert.equal(events.find(event => event.event_type === 'media_stream_started').payload.established_to_media_started_ms >= 0, true);

  call.emit('end');
  await result.completion;
});

test('VoiceApplication treats direct AI app route decisions as local realtime sessions without legacy app fallback telemetry', async () => {
  const stream = new FakeVoiceStream();
  const bridgeEvents = [];
  const events = [];
  let contextPayload;
  const client = {
    routeInbound: async () => ({
      action: 'ai',
      app_ref: 'ai-app-1',
      reason: 'ai_route',
      account_id: 6,
      number_ref: 'number-ai-1'
    }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    sendEvent: async payload => { events.push(payload); return { status: 'ok' }; },
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
    async transferToApp() { throw new Error('direct AI route should not transfer to a legacy app'); }
  });
  const app = new VoiceApplication({
    client,
    realtimeFactory: () => ({ connect: async () => {}, close: () => {} })
  });

  const result = await app.handleCall(call, {
    call_ref: 'call-direct-ai-app',
    from: '+155****1001',
    to: '+155****7001',
    app_ref: 'ai-app-1'
  });

  assert.equal(result.mode, 'realtime');
  assert.equal(call.answerCount, 1);
  assert.equal(contextPayload.account_id, 6);
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started']);
  assert.equal(bridgeEvents[0].app_ref, 'ai-app-1');
  assert.equal(bridgeEvents[0].metadata.route_app_ref, 'ai-app-1');
  assert.equal(bridgeEvents[0].metadata.topology, 'direct_ai');
  assert.equal(events.find(event => event.event_type === 'call_started').payload.route_app_ref, 'ai-app-1');
  assert.equal(events.find(event => event.event_type === 'call_started').payload.topology, 'direct_ai');

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
    from: '+155****1001',
    to: '+155****7001',
    number_ref: 'number-1'
  });

  assert.equal(result.mode, 'app');
  assert.equal(call.answerCount, 1);
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'app_routing']);
  assert.equal(handoffs[0].app_ref, 'target-app-1');
});

test('VoiceApplication closes passive recording when app handoff fails', async () => {
  const stream = new FakeVoiceStream();
  const bridgeEvents = [];
  const writes = [];
  const hangups = [];
  const client = {
    routeInbound: async () => ({ action: 'app', app_ref: 'target-app-1', reason: 'app_route', recording: { enabled: true } }),
    sendBridgeEvent: async payload => { bridgeEvents.push(payload); return { status: 'ok' }; },
    getContext: async () => { throw new Error('AI context should not be loaded for app routes'); }
  };
  const call = {
    async answer() {},
    async transferToApp() { throw new Error('provider app handoff failed'); },
    async hangup(payload) { hangups.push(payload); }
  };
  const recordingWriter = {
    start: async metadata => { writes.push(['start', metadata]); return true; },
    close: async () => { writes.push(['close']); return {}; }
  };
  const app = new VoiceApplication({
    client,
    managedStreamStarter: async () => stream,
    recordingWriterFactory: () => recordingWriter
  });

  const result = await app.handleCall(call, { call_ref: 'call-app-fail' });
  await result.completion;

  assert.equal(result.mode, 'app_failed');
  assert.equal(stream.closed, true);
  assert.deepEqual(writes.map(([kind]) => kind), ['start', 'close']);
  assert.equal(hangups[0].reason, 'provider app handoff failed');
  assert.deepEqual(bridgeEvents.map(event => event.event), ['session_started', 'app_routing', 'session_failed']);
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
