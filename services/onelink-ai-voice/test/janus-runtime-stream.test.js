const assert = require('node:assert/strict');
const test = require('node:test');
const EventEmitter = require('node:events');

const { createJanusRuntimeMediaStreamFactory } = require('../src/janus/runtime-stream');

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

test('createJanusRuntimeMediaStreamFactory opens only Janus SIP runtime stream requests', async () => {
  FakeWebSocket.instances = [];
  const factory = createJanusRuntimeMediaStreamFactory({ WebSocketImpl: FakeWebSocket });

  const stream = await factory({
    request: {
      call_ref: 'sipuni:janus-ai:call-1',
      transport: 'janus_sip',
      media_session_ref: 'janus-media-1',
      runtime_stream: {
        runtime_session_id: 'janus-rt-1',
        stream_url: 'ws://janus-ai-gateway/sessions/janus-rt-1/runtime-stream',
        stream_token: 'secret',
        codec: 'pcm_s16le',
        input_sample_rate: 16000,
        output_sample_rate: 8000
      }
    }
  });

  assert.equal(stream.callRef, 'sipuni:janus-ai:call-1');
  assert.equal(stream.streamRef, 'janus-rt-1');
  assert.equal(stream.mediaSessionRef, 'janus-media-1');
  assert.equal(stream.transport, 'janus_sip');
  assert.equal(FakeWebSocket.instances[0].url, 'ws://janus-ai-gateway/sessions/janus-rt-1/runtime-stream');
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
  assert.equal(seen.mediaSessionRef, 'janus-media-1');
  assert.equal(seen.transport, 'janus_sip');

  stream.write({ type: 'AUDIO_OUT', data: Buffer.from([4, 5]) });
  assert.deepEqual(JSON.parse(FakeWebSocket.instances[0].sent[0]), {
    type: 'AUDIO_OUT',
    data: Buffer.from([4, 5]).toString('base64')
  });
});

test('createJanusRuntimeMediaStreamFactory ignores non-Janus requests', async () => {
  const factory = createJanusRuntimeMediaStreamFactory({ WebSocketImpl: FakeWebSocket });
  const stream = await factory({
    request: {
      call_ref: 'whatsapp:call-1',
      transport: 'whatsapp_cloud',
      runtime_stream: {
        runtime_session_id: 'rt-1',
        stream_url: 'ws://media/sessions/rt-1'
      }
    }
  });

  assert.equal(stream, null);
});

test('createJanusRuntimeMediaStreamFactory fails closed without a stream_url', async () => {
  const factory = createJanusRuntimeMediaStreamFactory({ WebSocketImpl: FakeWebSocket });

  await assert.rejects(
    () => factory({
      request: {
        call_ref: 'sipuni:janus-ai:call-1',
        transport: 'janus_sip',
        runtime_stream: { runtime_session_id: 'janus-rt-1' }
      }
    }),
    /runtime stream_url is required/
  );
});
