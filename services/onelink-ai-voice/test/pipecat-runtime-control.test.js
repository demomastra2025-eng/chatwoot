const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { Readable } = require('node:stream');
const { PipecatRuntimeControlRegistry } = require('../src/pipecat/runtime-control');

function controlledCall({ transferEvent = 'answered' } = {}) {
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
    return true;
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
