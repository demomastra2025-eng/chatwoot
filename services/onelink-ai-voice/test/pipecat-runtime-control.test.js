const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { Readable } = require('node:stream');
const { PipecatRuntimeControlRegistry } = require('../src/pipecat/runtime-control');

function controlledCall({ transferEvent = 'answered', hangupResult = true } = {}) {
  const call = new EventEmitter();
  call.transfers = [];
  call.hangups = 0;
  call.transfer = async payload => {
    call.transfers.push(payload);
    const leg = new EventEmitter();
    if (transferEvent) setImmediate(() => leg.emit(transferEvent));
    return leg;
  };
  call.hangup = async () => {
    call.hangups += 1;
    call.emit('end');
    return hangupResult;
  };
  return call;
}

async function post(
  registry,
  capability,
  payload,
  token = capability.token,
  authorization = `Bearer ${token}`
) {
  const body = JSON.stringify(payload);
  const req = Readable.from([Buffer.from(body)]);
  req.method = 'POST';
  req.url = new URL(capability.control_url).pathname;
  req.headers = { authorization };
  let resolveResponse;
  const response = new Promise(resolve => { resolveResponse = resolve; });
  const res = {
    statusCode: 0,
    writableEnded: false,
    setHeader() {},
    end(value) {
      this.writableEnded = true;
      resolveResponse({ statusCode: this.statusCode, body: JSON.parse(value) });
    }
  };
  assert.equal(registry.handleRequest(req, res), true);
  return response;
}

function deferredPost(registry, capability, token = capability.token) {
  const req = new Readable({ read() {} });
  req.method = 'POST';
  req.url = new URL(capability.control_url).pathname;
  req.headers = { authorization: `Bearer ${token}` };
  let resolveResponse;
  const response = new Promise(resolve => { resolveResponse = resolve; });
  const res = {
    statusCode: 0,
    writableEnded: false,
    setHeader() {},
    end(value) {
      this.writableEnded = true;
      resolveResponse({ statusCode: this.statusCode, body: JSON.parse(value) });
    }
  };
  assert.equal(registry.handleRequest(req, res), true);
  return {
    response,
    send(payload) {
      req.push(Buffer.from(JSON.stringify(payload)));
      req.push(null);
    }
  };
}

test('Pipecat runtime control authorizes and de-duplicates SIP transfer', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall();
  const capability = registry.register(call);
  const payload = { action: 'transfer', operator_agent_aor: 'sip:1001@example.test', reason: 'requested' };

  const first = await post(registry, capability, payload);
  const duplicate = await post(registry, capability, payload);

  assert.equal(first.statusCode, 200);
  assert.deepEqual(first.body, { status: 'completed', action: 'transfer', outcome: 'answered' });
  assert.deepEqual(duplicate.body, first.body);
  assert.equal(call.transfers.length, 1);
  assert.deepEqual(call.transfers[0], { agent_aor: 'sip:1001@example.test', reason: 'requested' });
});

test('Pipecat runtime control rejects a wrong capability token', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall();
  const capability = registry.register(call);

  const response = await post(registry, capability, { action: 'end_call' }, 'wrong-token');

  assert.equal(response.statusCode, 401);
  assert.equal(call.hangups, 0);
});

test('Pipecat runtime control rejects a capability token without Bearer scheme', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall();
  const capability = registry.register(call);

  const response = await post(
    registry,
    capability,
    { action: 'end_call' },
    capability.token,
    capability.token
  );

  assert.equal(response.statusCode, 401);
  assert.equal(call.hangups, 0);
});

test('Pipecat runtime control rejects conflicting transfer replay', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall();
  const capability = registry.register(call);

  const first = await post(registry, capability, {
    action: 'transfer',
    operator_agent_aor: 'sip:1001@example.test'
  });
  const conflict = await post(registry, capability, {
    action: 'transfer',
    operator_agent_aor: 'sip:1002@example.test'
  });

  assert.equal(first.statusCode, 200);
  assert.equal(conflict.statusCode, 409);
  assert.equal(conflict.body.error, 'runtime_action_conflict');
  assert.equal(call.transfers.length, 1);
});

test('Pipecat runtime control reports terminal transfer failure', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall({ transferEvent: 'busy' });
  const capability = registry.register(call);

  const response = await post(registry, capability, {
    action: 'transfer',
    operator_agent_aor: 'sip:1001@example.test'
  });

  assert.equal(response.statusCode, 409);
  assert.equal(response.body.error, 'runtime_transfer_busy');
});

test('Pipecat runtime control accepts an answered outcome buffered before transfer returns', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall({ transferEvent: null });
  call.transfer = async payload => {
    call.transfers.push(payload);
    const leg = new EventEmitter();
    leg.terminalOutcome = 'answered';
    leg.emit('answered');
    return leg;
  };
  const capability = registry.register(call);

  const response = await post(registry, capability, {
    action: 'transfer',
    operator_agent_aor: 'sip:1001@example.test'
  });

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.outcome, 'answered');
  assert.equal(call.transfers.length, 1);
});

test('Pipecat runtime control times out a non-terminal transfer leg', async () => {
  const registry = new PipecatRuntimeControlRegistry({
    baseUrl: 'http://voice:8081',
    transferTimeoutMs: 5
  });
  const call = controlledCall({ transferEvent: null });
  const capability = registry.register(call);

  const response = await post(registry, capability, {
    action: 'transfer',
    operator_agent_aor: 'sip:1001@example.test'
  });

  assert.equal(response.statusCode, 504);
  assert.equal(response.body.error, 'runtime_transfer_timeout');
});

test('Pipecat runtime control ends a call idempotently', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall();
  const capability = registry.register(call);

  const first = await post(registry, capability, { action: 'end_call', reason: 'tool' });
  const duplicate = await post(registry, capability, { action: 'end_call', reason: 'tool' });

  assert.equal(first.statusCode, 200);
  assert.deepEqual(duplicate.body, first.body);
  assert.equal(call.hangups, 1);
});

test('Pipecat runtime control reports a confirmed Janus hangup outcome', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall({
    hangupResult: { accepted: true, confirmed: true, outcome: 'janus_hangup_event' }
  });
  const capability = registry.register(call);

  const response = await post(registry, capability, { action: 'end_call' });

  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.body, {
    status: 'completed',
    action: 'end_call',
    confirmed: true,
    outcome: 'janus_hangup_event'
  });
});

test('Pipecat runtime control rejects a transport-level hangup rejection', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall({ hangupResult: false });
  const capability = registry.register(call);

  const response = await post(registry, capability, { action: 'end_call' });

  assert.equal(response.statusCode, 409);
  assert.equal(response.body.error, 'runtime_hangup_rejected');
});

test('Pipecat runtime control remains valid through the configured call duration', async () => {
  let now = 1_000;
  const registry = new PipecatRuntimeControlRegistry({
    baseUrl: 'http://voice:8081',
    ttlMs: 300_000,
    now: () => now
  });
  const call = controlledCall();
  call.request = { routing: { call_limits: { max_duration_sec: 900 } } };
  const capability = registry.register(call);

  now += 315_000;
  const response = await post(registry, capability, { action: 'end_call', reason: 'tool' });

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.action, 'end_call');
  assert.equal(call.hangups, 1);
});

test('Pipecat runtime control expires after call duration plus cleanup grace', async () => {
  let now = 1_000;
  const registry = new PipecatRuntimeControlRegistry({
    baseUrl: 'http://voice:8081',
    ttlMs: 300_000,
    now: () => now
  });
  const call = controlledCall();
  call.request = { routing: { max_call_duration_seconds: 900 } };
  const capability = registry.register(call);

  now += 960_001;
  const response = await post(registry, capability, { action: 'end_call' });

  assert.equal(response.statusCode, 401);
  assert.equal(call.hangups, 0);
  assert.equal(registry.entries.size, 0);
});

test('Pipecat runtime control never slides its original capability deadline', async () => {
  let now = 1_000;
  const registry = new PipecatRuntimeControlRegistry({
    baseUrl: 'http://voice:8081',
    ttlMs: 300_000,
    now: () => now
  });
  const call = controlledCall({ transferEvent: 'busy' });
  const capability = registry.register(call);
  const entry = [...registry.entries.values()][0];
  const originalDeadline = entry.expiresAt;

  now += 60_000;
  const transfer = await post(registry, capability, {
    action: 'transfer',
    operator_agent_aor: 'sip:1001@example.test'
  });

  assert.equal(transfer.statusCode, 409);
  assert.equal(entry.expiresAt, originalDeadline);
  now = originalDeadline + 1;
  const endCall = await post(registry, capability, { action: 'end_call' });
  assert.equal(endCall.statusCode, 401);
  assert.equal(call.hangups, 0);
});

test('Pipecat runtime control rechecks expiry after reading a slow request body', async () => {
  let now = 1_000;
  const registry = new PipecatRuntimeControlRegistry({
    baseUrl: 'http://voice:8081',
    ttlMs: 300_000,
    now: () => now
  });
  const call = controlledCall();
  const capability = registry.register(call);
  const entry = [...registry.entries.values()][0];
  now = entry.expiresAt - 1;
  const request = deferredPost(registry, capability);

  now = entry.expiresAt + 1;
  request.send({ action: 'end_call' });
  const response = await request.response;

  assert.equal(response.statusCode, 401);
  assert.equal(call.hangups, 0);
  assert.equal(registry.entries.size, 0);
});

test('Pipecat runtime control rejects end_call while SIP transfer is in flight', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall();
  const capability = registry.register(call);

  const transfer = post(registry, capability, {
    action: 'transfer',
    operator_agent_aor: 'sip:1001@example.test'
  });
  const endCall = await post(registry, capability, { action: 'end_call', reason: 'concurrent' });

  assert.equal(endCall.statusCode, 409);
  assert.equal(endCall.body.error, 'runtime_terminal_action_conflict');
  assert.equal((await transfer).statusCode, 200);
  assert.equal(call.transfers.length, 1);
  assert.equal(call.hangups, 0);
});

test('Pipecat runtime control allows end_call after a failed SIP transfer', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall({ transferEvent: 'busy' });
  const capability = registry.register(call);

  const transfer = await post(registry, capability, {
    action: 'transfer',
    operator_agent_aor: 'sip:1001@example.test'
  });
  const endCall = await post(registry, capability, { action: 'end_call', reason: 'transfer_failed' });

  assert.equal(transfer.statusCode, 409);
  assert.equal(transfer.body.error, 'runtime_transfer_busy');
  assert.equal(endCall.statusCode, 200);
  assert.equal(call.transfers.length, 1);
  assert.equal(call.hangups, 1);
});

test('Pipecat runtime control keeps a successful transfer authoritative', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall();
  const capability = registry.register(call);

  const transfer = await post(registry, capability, {
    action: 'transfer',
    operator_agent_aor: 'sip:1001@example.test'
  });
  const endCall = await post(registry, capability, { action: 'end_call', reason: 'late' });

  assert.equal(transfer.statusCode, 200);
  assert.equal(endCall.statusCode, 409);
  assert.equal(endCall.body.error, 'runtime_terminal_action_conflict');
  assert.equal(call.transfers.length, 1);
  assert.equal(call.hangups, 0);
});

test('Pipecat runtime control releases the capability when the call ends', async () => {
  const registry = new PipecatRuntimeControlRegistry({ baseUrl: 'http://voice:8081' });
  const call = controlledCall();
  const capability = registry.register(call);

  call.emit('end');
  await new Promise(resolve => setImmediate(resolve));
  const response = await post(registry, capability, { action: 'end_call' });

  assert.equal(response.statusCode, 401);
  assert.equal(registry.entries.size, 0);
});
