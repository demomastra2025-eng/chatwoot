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

test('VoiceApplication falls back safely when realtime setup fails after context bootstrap', async () => {
  const controls = [];
  const greetings = [];
  const client = {
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
