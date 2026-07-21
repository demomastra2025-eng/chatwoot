const assert = require('node:assert/strict');
const test = require('node:test');
const EventEmitter = require('node:events');

const { createWhatsappRuntimeMediaStreamFactory } = require('../src/whatsapp/runtime-stream');

class FakeWebSocket extends EventEmitter {
  constructor(url, options) {
    super();
    this.url = url;
    this.options = options;
    this.sent = [];
    FakeWebSocket.instances.push(this);
    queueMicrotask(() => this.emit('open'));
  }

  send(payload) {
    this.sent.push(payload);
  }

  close() {
    this.closed = true;
    this.emit('close');
  }
}
FakeWebSocket.instances = [];

class FakeClosingWebSocket extends EventEmitter {
  constructor(url) {
    super();
    this.url = url;
    queueMicrotask(() => this.emit('close'));
  }

  send() {}

  close() {
    this.emit('close');
  }
}

test('createWhatsappRuntimeMediaStreamFactory opens the one-time runtime stream contract', async () => {
  const factory = createWhatsappRuntimeMediaStreamFactory({ WebSocketImpl: FakeWebSocket });

  const stream = await factory({
    request: {
      call_ref: 'whatsapp:wa-call-1',
      runtime_stream: {
        runtime_session_id: 'rt-wa-1',
        stream_url: 'ws://media/sessions/sess-1/runtime-stream',
        stream_token: 'secret',
        codec: 'pcm_s16le',
        input_sample_rate: 16000,
        output_sample_rate: 24000
      }
    }
  });

  assert.equal(stream.callRef, 'whatsapp:wa-call-1');
  assert.equal(stream.streamRef, 'rt-wa-1');
  assert.equal(stream.mediaSessionRef, 'rt-wa-1');
  assert.equal(FakeWebSocket.instances[0].url, 'ws://media/sessions/sess-1/runtime-stream');
  assert.equal(FakeWebSocket.instances[0].options.headers.authorization, 'Bearer secret');

  let seen;
  stream.onPayload(payload => { seen = payload; });
  FakeWebSocket.instances[0].emit('message', JSON.stringify({
    type: 'AUDIO_IN',
    data: Buffer.from([1, 2, 3]).toString('base64'),
    mime_type: 'audio/pcm;rate=16000'
  }));

  assert.deepEqual([...seen.data], [1, 2, 3]);
  assert.equal(seen.type, 'AUDIO_IN');
  assert.equal(seen.mimeType, 'audio/pcm;rate=16000');

  stream.write({ type: 'AUDIO_OUT', data: Buffer.from([4, 5]) });
  assert.deepEqual(JSON.parse(FakeWebSocket.instances[0].sent[0]), {
    type: 'AUDIO_OUT',
    data: Buffer.from([4, 5]).toString('base64')
  });

  assert.doesNotThrow(() => FakeWebSocket.instances[0].emit('message', 'not-json'));
});

test('createWhatsappRuntimeMediaStreamFactory fails closed when the runtime stream closes before open', async () => {
  const factory = createWhatsappRuntimeMediaStreamFactory({ WebSocketImpl: FakeClosingWebSocket });

  await assert.rejects(
    () => factory({
      request: {
        call_ref: 'whatsapp:wa-call-1',
        runtime_stream: {
          runtime_session_id: 'rt-wa-1',
          stream_url: 'ws://media/sessions/sess-1/runtime-stream?auth=closed',
          stream_token: 'closed-token'
        }
      }
    }),
    /runtime stream closed before open/
  );
});

test('createWhatsappRuntimeMediaStreamFactory fails closed without a stream_url', async () => {
  const factory = createWhatsappRuntimeMediaStreamFactory({ WebSocketImpl: FakeWebSocket });

  await assert.rejects(
    () => factory({ request: { call_ref: 'whatsapp:wa-call-1', runtime_stream: { runtime_session_id: 'rt-wa-1' } } }),
    /runtime stream_url is required/
  );
});

test('createWhatsappRuntimeMediaStreamFactory rejects query and missing stream capabilities', async () => {
  const factory = createWhatsappRuntimeMediaStreamFactory({ WebSocketImpl: FakeWebSocket });

  await assert.rejects(
    () => factory({
      request: {
        runtime_stream: {
          runtime_session_id: 'rt-wa-query',
          stream_url: 'ws://media/sessions/sess-1/runtime-stream?token=query-token',
          stream_token: 'header-token'
        }
      }
    }),
    /must not be carried in the URL/
  );
  await assert.rejects(
    () => factory({
      request: {
        runtime_stream: {
          runtime_session_id: 'rt-wa-missing-token',
          stream_url: 'ws://media/sessions/sess-1/runtime-stream'
        }
      }
    }),
    /stream_token is required/
  );
});
