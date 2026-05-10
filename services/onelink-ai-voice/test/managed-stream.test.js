const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { startManagedVoiceStream, loadFonosterInternalsFrom } = require('../src/fonoster/managed-stream');

class FakeInternalStream extends EventEmitter {
  constructor() {
    super();
    this.payloadInHandlers = [];
    this.closed = false;
  }

  onPayload(handler) {
    this.on('payloadOut', handler);
  }

  onPayloadIn(handler) {
    this.payloadInHandlers.push(handler);
  }

  write(payload) {
    for (const handler of this.payloadInHandlers) handler(payload);
  }

  close() {
    this.closed = true;
  }
}

test('startManagedVoiceStream uses Fonoster StartStream/Stream/StopStream natively and preserves mediaSessionRef/streamRef', async () => {
  const startRuns = [];
  const stopRuns = [];
  const voiceWrites = [];
  const voiceTransport = Object.assign(new EventEmitter(), {
    write(payload) { voiceWrites.push(payload); }
  });
  class FakeStartStream {
    constructor(request, voice) {
      this.request = request;
      this.voice = voice;
    }

    async run(payload) {
      startRuns.push({ request: this.request, voice: this.voice, payload });
      return { startStreamResponse: { streamRef: 'managed-stream-1' } };
    }
  }
  class FakeStopStream {
    constructor(request, voice) {
      this.request = request;
      this.voice = voice;
    }

    async run(payload) {
      stopRuns.push({ request: this.request, voice: this.voice, payload });
      return {};
    }
  }

  const call = {
    request: { callRef: 'runtime-call-1', mediaSessionRef: 'media-session-1' },
    voice: voiceTransport,
    stream() { throw new Error('native managed stream should not use fallback call.stream'); }
  };

  const stream = await startManagedVoiceStream(call, {
    direction: 'both',
    format: 'wav',
    internals: { StartStream: FakeStartStream, StopStream: FakeStopStream, Stream: FakeInternalStream }
  });

  assert.equal(stream.streamRef, 'managed-stream-1');
  assert.equal(stream.mediaSessionRef, 'media-session-1');
  assert.equal(stream.format, 'wav');
  assert.deepEqual(startRuns[0].payload, { mediaSessionRef: 'media-session-1', direction: 'both', format: 'wav' });

  const inputPayloads = [];
  stream.onPayload(payload => inputPayloads.push(payload));
  voiceTransport.emit('data', {
    streamPayload: {
      type: 'audio_in',
      mediaSessionRef: 'media-session-1',
      streamRef: 'managed-stream-1',
      data: Buffer.from([1, 2, 3])
    }
  });
  assert.equal(inputPayloads.length, 1);
  assert.equal(inputPayloads[0].streamRef, 'managed-stream-1');

  stream.write({ type: 'audio_out', data: Buffer.from([4, 5]) });
  assert.equal(voiceWrites.length, 1);
  assert.deepEqual(voiceWrites[0].streamPayload, {
    type: 'audio_out',
    data: Buffer.from([4, 5]),
    mediaSessionRef: 'media-session-1',
    streamRef: 'managed-stream-1',
    format: 'wav'
  });

  stream.close();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(stream.closed, true);
  assert.deepEqual(stopRuns[0].payload, { mediaSessionRef: 'media-session-1', streamRef: 'managed-stream-1' });

  inputPayloads.length = 0;
  voiceTransport.emit('data', { streamPayload: { type: 'audio_in', streamRef: 'managed-stream-1', data: Buffer.from([9]) } });
  assert.equal(inputPayloads.length, 0, 'close must detach native transport listener');
});

test('loadFonosterInternalsFrom supports the @fonoster/voice 0.18 dist/verbs/Stream export path', () => {
  const calls = [];
  const expected = { StartStream: class {}, StopStream: class {}, Stream: class {} };
  const loader = path => {
    calls.push(path);
    if (path === '@fonoster/voice/dist/verbs/Stream') return expected;
    throw new Error(`missing ${path}`);
  };

  assert.equal(loadFonosterInternalsFrom(loader), expected);
  assert.ok(calls.includes('@fonoster/voice/dist/verbs/Stream'));
});

test('startManagedVoiceStream falls back to call.stream when native Fonoster internals are unavailable', async () => {
  const fallbackStream = new EventEmitter();
  const call = {
    streamCalls: [],
    async stream(options) {
      this.streamCalls.push(options);
      return fallbackStream;
    }
  };

  const stream = await startManagedVoiceStream(call, { direction: 'both', format: 'wav', internals: {} });

  assert.equal(stream, fallbackStream);
  assert.deepEqual(call.streamCalls, [{ direction: 'both', format: 'wav' }]);
});
