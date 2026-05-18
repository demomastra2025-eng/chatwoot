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
    mediaSessionRef: 'media-session-1',
    streamRef: 'managed-stream-1',
    format: 'WAV',
    type: 'AUDIO_OUT',
    data: Buffer.from([4, 5])
  });

  stream.close();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(stream.closed, true);
  assert.deepEqual(stopRuns[0].payload, { mediaSessionRef: 'media-session-1', streamRef: 'managed-stream-1' });

  inputPayloads.length = 0;
  voiceTransport.emit('data', { streamPayload: { type: 'audio_in', streamRef: 'managed-stream-1', data: Buffer.from([9]) } });
  assert.equal(inputPayloads.length, 0, 'close must detach native transport listener');
});

test('startManagedVoiceStream writes outbound audio using the Fonoster 0.18 StreamPayload contract', async () => {
  const voiceWrites = [];
  const voiceTransport = Object.assign(new EventEmitter(), {
    write(payload) { voiceWrites.push(payload); }
  });
  class FakeStartStream {
    async run() {
      return { startStreamResponse: { streamRef: 'managed-stream-contract' } };
    }
  }
  class FakeStopStream {
    async run() { return {}; }
  }
  const call = {
    request: { callRef: 'runtime-call-contract', mediaSessionRef: 'media-session-contract' },
    voice: voiceTransport
  };
  const stream = await startManagedVoiceStream(call, {
    direction: 'BOTH',
    format: 'WAV',
    internals: { StartStream: FakeStartStream, StopStream: FakeStopStream, Stream: FakeInternalStream }
  });

  stream.write({
    type: 'audio_out',
    format: 'wav',
    media_session_ref: 'wrong-snake-media-ref',
    stream_ref: 'wrong-snake-stream-ref',
    data: Buffer.from([4, 5, 6, 7]),
    debug: 'must-not-leak-to-fonoster'
  });

  assert.equal(voiceWrites.length, 1);
  assert.deepEqual(voiceWrites[0], {
    streamPayload: {
      mediaSessionRef: 'media-session-contract',
      streamRef: 'managed-stream-contract',
      format: 'WAV',
      type: 'AUDIO_OUT',
      data: Buffer.from([4, 5, 6, 7])
    }
  });
});

test('startManagedVoiceStream reports first outbound write telemetry with audio validity stats', async () => {
  const telemetry = [];
  const voiceTransport = Object.assign(new EventEmitter(), {
    write() { return true; }
  });
  class FakeStartStream {
    async run() {
      return { startStreamResponse: { streamRef: 'managed-stream-telemetry' } };
    }
  }
  class FakeStopStream {
    async run() { return {}; }
  }
  const call = {
    request: { callRef: 'runtime-call-telemetry', mediaSessionRef: 'media-session-telemetry' },
    voice: voiceTransport
  };
  const stream = await startManagedVoiceStream(call, {
    direction: 'BOTH',
    format: 'WAV',
    onAudioOutWrite: payload => telemetry.push(payload),
    internals: { StartStream: FakeStartStream, StopStream: FakeStopStream, Stream: FakeInternalStream }
  });

  const audio = Buffer.alloc(4);
  audio.writeInt16LE(0, 0);
  audio.writeInt16LE(1000, 2);
  stream.write({ type: 'audio_out', kind: 'model_audio', data: audio });

  assert.equal(telemetry.length, 1);
  assert.equal(telemetry[0].first_audio_out_write_bytes, 4);
  assert.equal(telemetry[0].first_audio_out_write_kind, 'model_audio');
  assert.equal(telemetry[0].first_audio_out_non_zero_ratio, 0.5);
  assert.equal(Math.round(telemetry[0].first_audio_out_rms), 707);
  assert.equal(telemetry[0].stream_ref, 'managed-stream-telemetry');
  assert.equal(telemetry[0].media_session_ref, 'media-session-telemetry');
  assert.match(telemetry[0].first_audio_out_write_at, /^\d{4}-\d{2}-\d{2}T/);
});

test('startManagedVoiceStream refuses a native media stream without a streamRef', async () => {
  const voiceTransport = Object.assign(new EventEmitter(), {
    write() { throw new Error('no outbound write is allowed without a streamRef'); }
  });
  class MissingStreamRefStartStream {
    async run() {
      return { startStreamResponse: {} };
    }
  }
  class FakeStopStream {
    async run() { return {}; }
  }
  const call = {
    request: { callRef: 'runtime-call-missing-stream-ref', mediaSessionRef: 'media-session-missing-stream-ref' },
    voice: voiceTransport
  };

  await assert.rejects(
    () => startManagedVoiceStream(call, {
      direction: 'BOTH',
      format: 'WAV',
      internals: { StartStream: MissingStreamRefStartStream, StopStream: FakeStopStream, Stream: FakeInternalStream }
    }),
    error => {
      assert.equal(error.reason, 'start_stream_missing_stream_ref');
      assert.equal(error.source, 'fonoster_start_stream');
      return true;
    }
  );
});

test('startManagedVoiceStream drops malformed outbound payloads before Fonoster write', async () => {
  const voiceWrites = [];
  const voiceTransport = Object.assign(new EventEmitter(), {
    write(payload) { voiceWrites.push(payload); }
  });
  class FakeStartStream {
    async run() {
      return { startStreamResponse: { streamRef: 'managed-stream-guarded' } };
    }
  }
  class FakeStopStream {
    async run() { return {}; }
  }
  const call = {
    request: { callRef: 'runtime-call-guarded', mediaSessionRef: 'media-session-guarded' },
    voice: voiceTransport
  };

  const stream = await startManagedVoiceStream(call, {
    direction: 'BOTH',
    format: 'WAV',
    internals: { StartStream: FakeStartStream, StopStream: FakeStopStream, Stream: FakeInternalStream }
  });

  stream.write({ type: 'debug', data: Buffer.from([1, 2, 3]) });
  stream.write({ type: 'audio_out', data: Buffer.alloc(0) });
  stream.write({ type: 'audio_out', data: 'not-binary-audio' });
  assert.equal(voiceWrites.length, 0);

  stream.write({ type: 'audio_out', data: Buffer.from([4, 5]) });
  assert.equal(voiceWrites.length, 1);
  assert.deepEqual(voiceWrites[0].streamPayload, {
    mediaSessionRef: 'media-session-guarded',
    streamRef: 'managed-stream-guarded',
    format: 'WAV',
    type: 'AUDIO_OUT',
    data: Buffer.from([4, 5])
  });
});

test('startManagedVoiceStream fails fast when Fonoster StartStream response never arrives', async () => {
  const voiceTransport = Object.assign(new EventEmitter(), {
    write() {}
  });
  class HangingStartStream {
    async run() {
      return new Promise(() => {});
    }
  }
  class FakeStopStream {
    async run() {
      return {};
    }
  }
  const call = {
    request: { callRef: 'runtime-call-timeout', mediaSessionRef: 'media-session-timeout' },
    voice: voiceTransport,
    stream() { throw new Error('native managed stream should not use fallback call.stream'); }
  };

  await assert.rejects(
    () => startManagedVoiceStream(call, {
      direction: 'both',
      format: 'wav',
      startStreamResponseTimeoutMs: 5,
      internals: { StartStream: HangingStartStream, StopStream: FakeStopStream, Stream: FakeInternalStream }
    }),
    error => {
      assert.equal(error.reason, 'start_stream_response_timeout');
      assert.equal(error.source, 'fonoster_start_stream');
      assert.equal(error.timeoutMs, 5);
      return true;
    }
  );
});

test('startManagedVoiceStream ignores late StartStream rejection after timeout', async () => {
  const voiceTransport = Object.assign(new EventEmitter(), {
    write() {}
  });
  const unhandledRejections = [];
  const onUnhandledRejection = reason => unhandledRejections.push(reason);
  class LateRejectingStartStream {
    async run() {
      return new Promise((_, reject) => {
        setTimeout(() => reject(new Error('late provider failure')), 20);
      });
    }
  }
  class FakeStopStream {
    async run() {
      return {};
    }
  }
  const call = {
    request: { callRef: 'runtime-call-late-timeout', mediaSessionRef: 'media-session-late-timeout' },
    voice: voiceTransport
  };

  process.on('unhandledRejection', onUnhandledRejection);
  try {
    await assert.rejects(
      () => startManagedVoiceStream(call, {
        direction: 'both',
        format: 'wav',
        startStreamResponseTimeoutMs: 5,
        internals: { StartStream: LateRejectingStartStream, StopStream: FakeStopStream, Stream: FakeInternalStream }
      }),
      { reason: 'start_stream_response_timeout' }
    );
    await new Promise(resolve => setTimeout(resolve, 30));
    assert.equal(unhandledRejections.length, 0);
  } finally {
    process.removeListener('unhandledRejection', onUnhandledRejection);
  }
});

test('startManagedVoiceStream stops a native stream that starts after the timeout', async () => {
  const voiceTransport = Object.assign(new EventEmitter(), {
    write() {}
  });
  const stopRuns = [];
  class LateResolvingStartStream {
    async run() {
      return new Promise(resolve => {
        setTimeout(() => resolve({ startStreamResponse: { streamRef: 'late-managed-stream' } }), 20);
      });
    }
  }
  class FakeStopStream {
    async run(payload) {
      stopRuns.push(payload);
      return {};
    }
  }
  const call = {
    request: { callRef: 'runtime-call-late-resolve', mediaSessionRef: 'media-session-late-resolve' },
    voice: voiceTransport
  };

  await assert.rejects(
    () => startManagedVoiceStream(call, {
      direction: 'both',
      format: 'wav',
      startStreamResponseTimeoutMs: 5,
      internals: { StartStream: LateResolvingStartStream, StopStream: FakeStopStream, Stream: FakeInternalStream }
    }),
    { reason: 'start_stream_response_timeout' }
  );
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.deepEqual(stopRuns, [{ mediaSessionRef: 'media-session-late-resolve', streamRef: 'late-managed-stream' }]);
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

test('startManagedVoiceStream fails fast when fallback call.stream never returns', async () => {
  const call = {
    streamCalls: [],
    stream(options) {
      this.streamCalls.push(options);
      return new Promise(() => {});
    }
  };

  await assert.rejects(
    () => startManagedVoiceStream(call, {
      direction: 'both',
      format: 'wav',
      startStreamResponseTimeoutMs: 5,
      internals: {}
    }),
    error => {
      assert.equal(error.reason, 'start_stream_response_timeout');
      assert.equal(error.source, 'fonoster_start_stream');
      assert.equal(error.timeoutMs, 5);
      return true;
    }
  );
  assert.deepEqual(call.streamCalls, [{ direction: 'both', format: 'wav' }]);
});

test('startManagedVoiceStream closes a fallback stream that appears after the timeout', async () => {
  const fallbackStream = new EventEmitter();
  fallbackStream.closed = false;
  fallbackStream.close = () => { fallbackStream.closed = true; };
  const call = {
    streamCalls: [],
    stream(options) {
      this.streamCalls.push(options);
      return new Promise(resolve => setTimeout(() => resolve(fallbackStream), 20));
    }
  };

  await assert.rejects(
    () => startManagedVoiceStream(call, {
      direction: 'both',
      format: 'wav',
      startStreamResponseTimeoutMs: 5,
      internals: {}
    }),
    { reason: 'start_stream_response_timeout' }
  );
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(fallbackStream.closed, true);
});
