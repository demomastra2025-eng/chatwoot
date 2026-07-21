const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { createWhatsappInternalHandler } = require('../src/whatsapp/internal-server');

function fakeReq({ method = 'POST', url = '/internal/whatsapp-cloud/calls', token = 'voice-secret', body = {} } = {}) {
  const listeners = {};
  return {
    method,
    url,
    headers: token === null ? {} : { authorization: `Bearer ${token}` },
    on(event, handler) { listeners[event] = handler; return this; },
    emitBody() {
      listeners.data?.(Buffer.from(JSON.stringify(body)));
      listeners.end?.();
    }
  };
}

function fakeRes() {
  return {
    statusCode: 200,
    headers: {},
    chunks: [],
    setHeader(name, value) { this.headers[name.toLowerCase()] = value; },
    end(chunk = '') { if (chunk) this.chunks.push(Buffer.from(chunk)); this.ended = true; this.emit?.('finish'); },
    json() { return JSON.parse(Buffer.concat(this.chunks).toString('utf8') || '{}'); }
  };
}

async function dispatch(handler, req, res) {
  const done = new Promise(resolve => { res.emit = resolve; });
  const handled = handler(req, res);
  req.emitBody?.();
  await done;
  return handled;
}

test('WhatsApp internal attach endpoint starts the voice app with the runtime stream request', async () => {
  let handled;
  const app = {
    async handleCall(call, payload) {
      handled = { call, payload };
      assert.equal(await call.answer(), true);
      return { mode: 'realtime', session: { callRef: payload.call_ref }, completion: Promise.resolve() };
    }
  };
  const handler = createWhatsappInternalHandler({ app, internalToken: 'voice-secret' });
  const body = {
    call_ref: 'whatsapp:wa-call-1',
    account_id: '42',
    media_session_id: 'media-1',
    runtime_stream: {
      runtime_session_id: 'rt-1',
      stream_url: 'ws://media/sessions/media-1/runtime-stream',
      stream_token: 't1'
    },
    routing: { action: 'ai_accept', reason: 'conversation_pending_ai_voice_enabled' }
  };

  const req = fakeReq({ body });
  const res = fakeRes();
  const handledRoute = await dispatch(handler, req, res);

  assert.equal(handledRoute, true);
  assert.equal(res.statusCode, 202);
  assert.deepEqual(res.json(), { status: 'accepted', mode: 'accepted', call_ref: 'whatsapp:wa-call-1' });
  assert.equal(handled.payload.media_session_ref, 'media-1');
  assert.equal(handled.call.request.runtime_stream.stream_url, body.runtime_stream.stream_url);
});

test('WhatsApp internal attach endpoint responds before the long running voice session completes', async () => {
  let startedResolve;
  const started = new Promise(resolve => { startedResolve = resolve; });
  const app = {
    async handleCall(call, payload) {
      startedResolve();
      assert.equal(payload.call_ref, 'whatsapp:wa-call-1');
      assert.equal(await call.answer(), true);
      return new Promise(() => {});
    }
  };
  const handler = createWhatsappInternalHandler({ app, internalToken: 'voice-secret' });
  const req = fakeReq({
    body: {
      call_ref: 'whatsapp:wa-call-1',
      media_session_id: 'media-1',
      routing: { action: 'ai' }
    }
  });
  const res = fakeRes();
  const done = new Promise(resolve => { res.emit = resolve; });

  assert.equal(handler(req, res), true);
  req.emitBody();
  await started;
  const result = await Promise.race([
    done.then(() => 'responded'),
    new Promise(resolve => setTimeout(() => resolve('timeout'), 50))
  ]);

  assert.equal(result, 'responded');
  assert.equal(res.statusCode, 202);
  assert.deepEqual(res.json(), { status: 'accepted', mode: 'accepted', call_ref: 'whatsapp:wa-call-1' });
});

test('WhatsApp internal attach delegates to exactly one Pipecat consumer when selected', async () => {
  let legacyCalls = 0;
  const pipecatCalls = [];
  const handler = createWhatsappInternalHandler({
    app: { handleCall: async () => { legacyCalls += 1; } },
    internalToken: 'voice-secret',
    runtimeSelector: {
      select(payload) {
        assert.equal(payload.provider, 'whatsapp_cloud');
        return 'pipecat';
      }
    },
    pipecatClient: {
      isAvailable: () => true,
      async attachWhatsapp(payload) {
        pipecatCalls.push(payload);
        return { session_id: 'pipecat-wa-1' };
      }
    }
  });
  const req = fakeReq({
    body: {
      call_ref: 'whatsapp:wa-call-pipecat',
      account_id: '42',
      inbox_id: '9',
      runtime_stream: {
        runtime_session_id: 'wa-rt-1',
        stream_url: 'ws://media/sessions/wa-rt-1/runtime-stream',
        stream_token: 't1',
        codec: 'pcm_s16le',
        input_sample_rate: 16000,
        output_sample_rate: 8000
      },
      routing: { action: 'ai' }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 202);
  assert.equal(legacyCalls, 0);
  assert.equal(pipecatCalls.length, 1);
  assert.equal(res.json().runtime_engine, 'pipecat');
  assert.equal(res.json().session_id, 'pipecat-wa-1');
});

test('WhatsApp preflight reaches Pipecat before the provider can be accepted', async () => {
  const preflightCalls = [];
  const handler = createWhatsappInternalHandler({
    app: { handleCall: async () => { throw new Error('attach must not run'); } },
    internalToken: 'voice-secret',
    runtimeSelector: { select: () => 'pipecat' },
    pipecatClient: {
      isAvailable: () => true,
      async ensureAvailable() {},
      async preflightWhatsapp(payload) { preflightCalls.push(payload); }
    }
  });
  const req = fakeReq({
    url: '/internal/whatsapp-cloud/preflight',
    body: {
      call_ref: 'whatsapp:wa-preflight-1',
      account_id: '42',
      inbox_id: '9',
      runtime_stream: {
        runtime_session_id: 'wa-rt-preflight-1',
        stream_url: 'ws://media/sessions/wa-rt-preflight-1/runtime-stream',
        stream_token: 'runtime-token',
        codec: 'pcm_s16le',
        input_sample_rate: 16000,
        output_sample_rate: 8000
      },
      routing: { action: 'ai' }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json(), { status: 'ready', runtime_engine: 'pipecat' });
  assert.equal(preflightCalls.length, 1);
});

test('WhatsApp internal attach rejects non-AI routes before selecting a runtime', async () => {
  let selections = 0;
  const handler = createWhatsappInternalHandler({
    app: { handleCall: async () => { throw new Error('must not run'); } },
    internalToken: 'voice-secret',
    runtimeSelector: { select: () => { selections += 1; return 'pipecat'; } },
    pipecatClient: { attachWhatsapp: async () => { throw new Error('must not run'); } }
  });
  const req = fakeReq({
    body: {
      call_ref: 'whatsapp:operator-route',
      routing: { action: 'operator' }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 422);
  assert.equal(res.json().error, 'non_ai_route_not_supported');
  assert.equal(selections, 0);
});

test('WhatsApp internal attach rejects a missing routing action before selecting a runtime', async () => {
  let selections = 0;
  const handler = createWhatsappInternalHandler({
    app: { handleCall: async () => { throw new Error('must not run'); } },
    internalToken: 'voice-secret',
    runtimeSelector: { select: () => { selections += 1; return 'pipecat'; } },
    pipecatClient: { attachWhatsapp: async () => { throw new Error('must not run'); } }
  });
  const req = fakeReq({ body: { call_ref: 'whatsapp:missing-route' } });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 422);
  assert.equal(res.json().error, 'ai_route_required');
  assert.equal(selections, 0);
});

test('WhatsApp internal attach endpoint fails closed without a matching bearer token', async () => {
  const handler = createWhatsappInternalHandler({ app: { handleCall: async () => { throw new Error('must not run'); } }, internalToken: 'voice-secret' });
  const req = fakeReq({ token: 'wrong', body: { call_ref: 'whatsapp:wa-call-1' } });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 401);
  assert.equal(res.json().error, 'unauthorized');
});

test('WhatsApp internal attach endpoint is disabled when the internal token is blank', async () => {
  const handler = createWhatsappInternalHandler({ app: { handleCall: async () => { throw new Error('must not run'); } }, internalToken: '' });
  const req = fakeReq({ token: 'voice-secret', body: { call_ref: 'whatsapp:wa-call-1' } });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 503);
  assert.equal(res.json().error, 'internal_token_required');
});
