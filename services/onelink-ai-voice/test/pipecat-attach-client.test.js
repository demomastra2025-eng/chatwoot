const test = require('node:test');
const assert = require('node:assert/strict');
const { PipecatAttachClient } = require('../src/pipecat/attach-client');

test('Pipecat attach client forwards one authenticated Janus attach', async () => {
  const calls = [];
  const client = new PipecatAttachClient({
    baseUrl: 'http://pipecat:8084/',
    token: 'pipecat-secret',
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return {
        ok: true,
        status: 202,
        async json() { return { status: 'accepted', session_id: 'runtime-1' }; }
      };
    }
  });

  const response = await client.attachJanus({ call_ref: 'call-1' });

  assert.equal(response.status, 'accepted');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'http://pipecat:8084/internal/janus-sip/calls');
  assert.equal(calls[0].options.headers.authorization, ['Bearer', 'pipecat-secret'].join(' '));
  assert.deepEqual(JSON.parse(calls[0].options.body), { call_ref: 'call-1' });
});

test('Pipecat attach client performs authenticated provider preflight', async () => {
  const calls = [];
  const client = new PipecatAttachClient({
    baseUrl: 'http://pipecat:8084',
    token: 'pipecat-secret',
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return {
        ok: true,
        status: 200,
        async json() { return { status: 'ready', runtime_engine: 'pipecat' }; }
      };
    }
  });

  const response = await client.preflightJanus({ call_ref: 'call-1' });

  assert.equal(response.status, 'ready');
  assert.equal(calls[0].url, 'http://pipecat:8084/internal/janus-sip/preflight');
  assert.equal(calls[0].options.headers.authorization, ['Bearer', 'pipecat-secret'].join(' '));
});

test('Pipecat attach client uses the WhatsApp provider preflight endpoint', async () => {
  const calls = [];
  const client = new PipecatAttachClient({
    baseUrl: 'http://pipecat:8084',
    token: 'pipecat-secret',
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return { ok: true, status: 200, async json() { return { status: 'ready' }; } };
    }
  });

  await client.preflightWhatsapp({ call_ref: 'whatsapp:call-1' });

  assert.equal(calls[0].url, 'http://pipecat:8084/internal/whatsapp-cloud/preflight');
  assert.equal(calls[0].options.headers.authorization, ['Bearer', 'pipecat-secret'].join(' '));
});

test('Pipecat attach client fails closed when unconfigured', async () => {
  const client = new PipecatAttachClient({ baseUrl: '', token: '' });

  await assert.rejects(
    client.attachJanus({ call_ref: 'call-1' }),
    error => error.code === 'pipecat_runtime_unavailable'
  );
});

test('Pipecat attach client verifies readiness without exposing the token in the URL', async () => {
  const calls = [];
  const client = new PipecatAttachClient({
    baseUrl: 'http://pipecat:8084',
    token: 'pipecat-secret',
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return { ok: true, status: 200 };
    }
  });

  assert.equal(await client.ensureAvailable(), true);
  assert.equal(calls[0].url, 'http://pipecat:8084/ready');
  assert.equal(calls[0].url.includes('pipecat-secret'), false);
  assert.equal(calls[0].options.headers.authorization, ['Bearer', 'pipecat-secret'].join(' '));
});

test('Pipecat attach errors do not expose response bodies or tokens', async () => {
  const client = new PipecatAttachClient({
    baseUrl: 'http://pipecat:8084',
    token: 'super-secret-token',
    fetchImpl: async () => ({
      ok: false,
      status: 500,
      async json() { return { error: 'provider_failed', token: 'leaked' }; }
    })
  });

  await assert.rejects(
    client.attachJanus({ call_ref: 'call-1' }),
    error => {
      assert.equal(error.code, 'pipecat_attach_failed');
      assert.equal(error.statusCode, 502);
      assert.equal(error.message.includes('super-secret-token'), false);
      assert.equal(error.message.includes('leaked'), false);
      return true;
    }
  );
});
