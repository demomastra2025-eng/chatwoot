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
    } else if (req.url === '/internal/voice/ai/event') {
      res.end(JSON.stringify({ status: 'ok', event_id: JSON.parse(body).event_id }));
    } else if (req.url === '/internal/voice/ai/runtime-handoff') {
      res.end(JSON.stringify({ status: 'handed_off', runtime_engine: 'onelink-ai-voice-node' }));
    } else if (req.url === '/internal/voice/ai/finalize') {
      res.end(JSON.stringify({ status: 'ok', event_id: JSON.parse(body).event_id, already_finalized: false }));
    } else if (req.url === '/internal/voice/ai/tools/find_contact') {
      res.end(JSON.stringify({ result: { contacts: [{ id: 1 }] } }));
    } else {
      res.statusCode = 404;
      res.end(JSON.stringify({ error: 'not_found' }));
    }
  });

  try {
    const client = new OnelinkClient({ baseUrl: seen.baseUrl, token: 'internal-token', timeoutMs: 1_000 });
    const context = await client.getContext(
      { call_ref: 'call-1', ingress_number: '+7000' },
      { capabilities: ['callback_handoff_v1', 'callback_handoff_v1'] }
    );
    const transcript = await client.sendTranscript({ call_ref: 'call-1', items: [{ speaker: 'caller', text: 'hello', final: true }] });
    const control = await client.sendControl({ call_ref: 'call-1', action: 'ai_answered' });
    const event = await client.sendEvent({ call_ref: 'call-1', event_id: 'evt-1', event_type: 'stream_started' });
    const handoff = await client.handoffRuntime({ call_ref: 'call-1', source_runtime_engine: 'pipecat' });
    const finalize = await client.finalizeCall({ call_ref: 'call-1', event_id: 'evt-finalize-1', status: 'completed' });
    const tool = await client.callTool('find_contact', { call_ref: 'call-1', arguments: { phone_number: '+7000' } });

    assert.equal(context.ai.provider, 'gemini-live');
    assert.equal(transcript.accepted, 1);
    assert.equal(control.action, 'ai_answered');
    assert.equal(event.event_id, 'evt-1');
    assert.equal(handoff.runtime_engine, 'onelink-ai-voice-node');
    assert.equal(finalize.event_id, 'evt-finalize-1');
    assert.deepEqual(tool, { contacts: [{ id: 1 }] });
    assert.equal(seen.requests.length, 7);
    assert.equal(seen.requests[0].method, 'POST');
    assert.equal(seen.requests[0].url, '/internal/voice/ai/context');
    assert.equal(JSON.parse(seen.requests[0].body).call_ref, 'call-1');
    assert.equal(seen.requests[0].headers['x-onelink-voice-capabilities'], 'callback_handoff_v1');
    assert.equal(seen.requests[3].headers['x-event-id'], 'evt-1');
    assert.equal(seen.requests[3].headers['x-idempotency-key'], 'evt-1');
    assert.equal(seen.requests[4].url, '/internal/voice/ai/runtime-handoff');
    assert.equal(seen.requests[5].headers['x-idempotency-key'], 'evt-finalize-1');
    assert.ok(seen.requests.every((request) => request.headers.authorization === 'Bearer internal-token'));
  } finally {
    await seen.close();
  }
});

test('OnelinkClient accepts contract base URL, token and endpoint path overrides', async () => {
  const seen = await withServer((req, res, body) => {
    res.setHeader('content-type', 'application/json');
    if (req.url === '/custom/event') {
      res.end(JSON.stringify({ status: 'ok', event_id: JSON.parse(body).event_id }));
    } else if (req.url === '/custom/finalize') {
      res.end(JSON.stringify({ status: 'ok', event_id: JSON.parse(body).event_id }));
    } else {
      res.statusCode = 404;
      res.end(JSON.stringify({ error: 'not_found' }));
    }
  });

  const previousBaseUrl = process.env.VOICE_AGENT_ONELINK_AI_BASE_URL;
  const previousSecret = process.env.VOICE_AGENT_ONELINK_AI_SHARED_SECRET;
  try {
    process.env.VOICE_AGENT_ONELINK_AI_BASE_URL = seen.baseUrl;
    process.env.VOICE_AGENT_ONELINK_AI_SHARED_SECRET = 'contract-secret';
    const client = new OnelinkClient({
      eventPath: '/custom/event',
      finalizePath: '/custom/finalize',
      timeoutMs: 1_000
    });

    await client.sendEvent({ event_id: 'evt-custom', event_type: 'stream_started' });
    await client.finalizeCall({ event_id: 'evt-finalize-custom', status: 'completed' });

    assert.equal(seen.requests[0].url, '/custom/event');
    assert.equal(seen.requests[1].url, '/custom/finalize');
    assert.ok(seen.requests.every((request) => request.headers.authorization === 'Bearer contract-secret'));
  } finally {
    if (previousBaseUrl === undefined) delete process.env.VOICE_AGENT_ONELINK_AI_BASE_URL;
    else process.env.VOICE_AGENT_ONELINK_AI_BASE_URL = previousBaseUrl;
    if (previousSecret === undefined) delete process.env.VOICE_AGENT_ONELINK_AI_SHARED_SECRET;
    else process.env.VOICE_AGENT_ONELINK_AI_SHARED_SECRET = previousSecret;
    await seen.close();
  }
});

test('OnelinkClient fetches Janus SIP profile configuration from Rails', async () => {
  const seen = await withServer((req, res) => {
    res.setHeader('content-type', 'application/json');
    if (req.url === '/internal/voice/ai/janus-sip/profiles') {
      res.end(JSON.stringify({ version: 'v1', profiles: [{ id: 12, provider: 'binotel' }] }));
    } else {
      res.statusCode = 404;
      res.end(JSON.stringify({ error: 'not_found' }));
    }
  });

  try {
    const client = new OnelinkClient({ baseUrl: seen.baseUrl, token: 'internal-token', timeoutMs: 1_000 });
    const profiles = await client.getJanusSipProfiles();

    assert.deepEqual(profiles, [{ id: 12, provider: 'binotel' }]);
    assert.equal(seen.requests[0].method, 'GET');
    assert.equal(seen.requests[0].url, '/internal/voice/ai/janus-sip/profiles');
    assert.equal(seen.requests[0].headers.authorization, 'Bearer internal-token');
  } finally {
    await seen.close();
  }
});

test('OnelinkClient rejects malformed Janus SIP profile configuration', async () => {
  const seen = await withServer((_req, res) => {
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ version: 'empty' }));
  });

  try {
    const client = new OnelinkClient({ baseUrl: seen.baseUrl, token: 'internal-token', timeoutMs: 1_000 });

    await assert.rejects(
      () => client.getJanusSipProfiles(),
      error => error.code === 'invalid_janus_sip_profiles_contract'
    );
  } finally {
    await seen.close();
  }
});

test('OnelinkClient calls Rails inbound route and bridge lifecycle event APIs', async () => {
  const seen = await withServer((req, res, body) => {
    res.setHeader('content-type', 'application/json');
    if (req.url === '/internal/voice/inbound/route') {
      const payload = JSON.parse(body);
      res.end(JSON.stringify({ action: 'operator', agent_aor: payload.operator_agent_aor || 'sip:1001@example.test' }));
    } else if (req.url === '/internal/voice/inbound/event') {
      res.end(JSON.stringify({ status: 'ok', event: JSON.parse(body).event }));
    } else {
      res.statusCode = 404;
      res.end(JSON.stringify({ error: 'not_found' }));
    }
  });

  try {
    const client = new OnelinkClient({ baseUrl: seen.baseUrl, token: 'internal-token', timeoutMs: 1_000 });
    const decision = await client.routeInbound(
      {
        call_ref: 'call-route-1',
        ingress_number: '+15551234567',
        caller_number: '+15557654321',
        number_ref: 'number-1',
        app_ref: 'runtime-app-1'
      },
      { capabilities: ['callback_handoff_v1', 'callback_handoff_v1'] }
    );
    const event = await client.sendBridgeEvent({
      event: 'session_started',
      call_ref: 'call-route-1',
      ingress_number: '+15551234567',
      caller_number: '+15557654321'
    });

    assert.equal(decision.action, 'operator');
    assert.equal(event.event, 'session_started');
    assert.equal(seen.requests.length, 2);
    assert.equal(seen.requests[0].method, 'POST');
    assert.equal(seen.requests[0].url, '/internal/voice/inbound/route');
    assert.equal(JSON.parse(seen.requests[0].body).app_ref, 'runtime-app-1');
    assert.equal(seen.requests[0].headers['x-onelink-voice-capabilities'], 'callback_handoff_v1');
    assert.equal(seen.requests[1].url, '/internal/voice/inbound/event');
    assert.ok(seen.requests.every((request) => request.headers.authorization === 'Bearer internal-token'));
  } finally {
    await seen.close();
  }
});

test('OnelinkClient uses bridge token for inbound route/events and AI token for AI callbacks', async () => {
  const seen = await withServer((req, res, body) => {
    res.setHeader('content-type', 'application/json');
    if (req.url === '/internal/voice/inbound/route') {
      res.end(JSON.stringify({ action: 'ai', bridge_call_ref: JSON.parse(body).bridge_call_ref }));
    } else if (req.url === '/internal/voice/inbound/event') {
      res.end(JSON.stringify({ status: 'ok', event: JSON.parse(body).event }));
    } else if (req.url === '/internal/voice/ai/context') {
      res.end(JSON.stringify({ call_ref: JSON.parse(body).call_ref, ai: { provider: 'gemini-live' } }));
    } else {
      res.statusCode = 404;
      res.end(JSON.stringify({ error: 'not_found' }));
    }
  });

  try {
    const client = new OnelinkClient({
      baseUrl: seen.baseUrl,
      token: 'ai-token',
      bridgeToken: 'bridge-token',
      timeoutMs: 1_000
    });

    await client.routeInbound({ call_ref: 'runtime-call-1', bridge_call_ref: 'bridge-call-1' });
    await client.sendBridgeEvent({ event: 'session_started', call_ref: 'runtime-call-1', bridge_call_ref: 'bridge-call-1' });
    await client.getContext({ call_ref: 'runtime-call-1' });

    assert.equal(seen.requests[0].url, '/internal/voice/inbound/route');
    assert.equal(seen.requests[0].headers.authorization, 'Bearer bridge-token');
    assert.equal(seen.requests[1].url, '/internal/voice/inbound/event');
    assert.equal(seen.requests[1].headers.authorization, 'Bearer bridge-token');
    assert.equal(seen.requests[2].url, '/internal/voice/ai/context');
    assert.equal(seen.requests[2].headers.authorization, 'Bearer ai-token');
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
