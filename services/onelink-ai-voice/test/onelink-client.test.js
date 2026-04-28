const test = require('node:test');
const assert = require('node:assert/strict');
const { createServer } = require('node:http');
const { OnelinkClient } = require('../src/onelink/client');

function withServer(handler) {
  const requests = [];
  const server = createServer(async (req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = Buffer.concat(chunks).toString();
      requests.push({ method: req.method, url: req.url, headers: req.headers, body });
      handler(req, res, body);
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({ baseUrl: `http://127.0.0.1:${port}`, requests, close: () => new Promise((r) => server.close(r)) });
    });
  });
}

test('OnelinkClient authenticates and calls Rails context/transcript/control/tool APIs', async () => {
  const seen = await withServer((req, res, body) => {
    res.setHeader('content-type', 'application/json');
    if (req.url.startsWith('/internal/voice/ai/context')) {
      res.end(JSON.stringify({ call_ref: 'call-1', ai: { provider: 'gemini-live' }, tools: [{ name: 'find_contact' }] }));
    } else if (req.url === '/internal/voice/ai/transcript') {
      res.end(JSON.stringify({ status: 'ok', accepted: JSON.parse(body).items.length }));
    } else if (req.url === '/internal/voice/ai/control') {
      res.end(JSON.stringify({ status: 'ok', action: JSON.parse(body).action }));
    } else if (req.url === '/internal/voice/ai/tools/find_contact') {
      res.end(JSON.stringify({ result: { contacts: [{ id: 1 }] } }));
    } else {
      res.statusCode = 404;
      res.end(JSON.stringify({ error: 'not_found' }));
    }
  });

  try {
    const client = new OnelinkClient({ baseUrl: seen.baseUrl, token: 'internal-token', timeoutMs: 1_000 });
    const context = await client.getContext({ call_ref: 'call-1', ingress_number: '+7000' });
    const transcript = await client.sendTranscript({ call_ref: 'call-1', items: [{ speaker: 'caller', text: 'hello', final: true }] });
    const control = await client.sendControl({ call_ref: 'call-1', action: 'ai_answered' });
    const tool = await client.callTool('find_contact', { call_ref: 'call-1', arguments: { phone_number: '+7000' } });

    assert.equal(context.ai.provider, 'gemini-live');
    assert.equal(transcript.accepted, 1);
    assert.equal(control.action, 'ai_answered');
    assert.deepEqual(tool, { contacts: [{ id: 1 }] });
    assert.equal(seen.requests.length, 4);
    assert.ok(seen.requests[0].url.includes('call_ref=call-1'));
    assert.ok(seen.requests.every((request) => request.headers.authorization === 'Bearer internal-token'));
  } finally {
    await seen.close();
  }
});

test('OnelinkClient returns structured errors without leaking tokens', async () => {
  const seen = await withServer((_req, res) => {
    res.statusCode = 503;
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ error: 'unavailable', message: 'Rails unavailable' }));
  });

  try {
    const client = new OnelinkClient({ baseUrl: seen.baseUrl, token: 'super-secret-token', timeoutMs: 1_000 });
    await assert.rejects(
      () => client.sendControl({ call_ref: 'call-1', action: 'session_failed' }),
      (error) => {
        assert.equal(error.status, 503);
        assert.equal(error.code, 'unavailable');
        assert.match(error.message, /Rails unavailable/);
        assert.doesNotMatch(error.message, /super-secret-token/);
        return true;
      }
    );
  } finally {
    await seen.close();
  }
});
