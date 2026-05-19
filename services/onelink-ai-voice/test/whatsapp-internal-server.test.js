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
    runtime_stream: { runtime_session_id: 'rt-1', stream_url: 'ws://media/sessions/media-1/runtime-stream?token=t1' },
    routing: { action: 'ai_accept', reason: 'conversation_pending_ai_voice_enabled' }
  };

  const req = fakeReq({ body });
  const res = fakeRes();
  const handledRoute = await dispatch(handler, req, res);

  assert.equal(handledRoute, true);
  assert.equal(res.statusCode, 202);
  assert.deepEqual(res.json(), { status: 'accepted', mode: 'realtime', call_ref: 'whatsapp:wa-call-1' });
  assert.equal(handled.payload.media_session_ref, 'media-1');
  assert.equal(handled.call.request.runtime_stream.stream_url, body.runtime_stream.stream_url);
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
