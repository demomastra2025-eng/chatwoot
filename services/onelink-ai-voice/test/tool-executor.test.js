const test = require('node:test');
const assert = require('node:assert/strict');
const { ToolExecutor } = require('../src/tools/tool-executor');

test('ToolExecutor wraps Rails tools with start/complete control events', async () => {
  const controls = [];
  const toolPayloads = [];
  const client = {
    sendControl: async (payload) => { controls.push(payload); return { status: 'ok' }; },
    callTool: async (name, payload) => { toolPayloads.push(payload); return { tool: name, arguments: payload.arguments }; }
  };
  const executor = new ToolExecutor({
    client,
    callRef: 'call-1',
    timeoutMs: 100,
    scopeProvider: () => ({ account_id: 42, number_ref: 'num-1' })
  });

  const result = await executor.execute('find_contact', { phone_number: '+7000' });

  assert.deepEqual(result, { ok: true, result: { tool: 'find_contact', arguments: { phone_number: '+7000' } } });
  assert.deepEqual(controls.map((event) => event.action), ['tool_started', 'tool_completed']);
  assert.equal(controls[0].metadata.tool_name, 'find_contact');
  assert.ok(controls.every((event) => event.account_id === 42));
  assert.equal(toolPayloads[0].account_id, 42);
  assert.equal(toolPayloads[0].number_ref, 'num-1');
});

test('ToolExecutor converts timeout into fallback, keeps tool running, and emits async completion', async () => {
  const controls = [];
  const toolPayloads = [];
  const client = {
    sendControl: async (payload) => { controls.push(payload); return { status: 'ok' }; },
    callTool: async (_name, payload) => {
      toolPayloads.push(payload);
      return new Promise((resolve) => setTimeout(() => resolve({ answer: 'late result' }), 30));
    }
  };
  const executor = new ToolExecutor({ client, callRef: 'call-1', timeoutMs: 5 });

  const result = await executor.execute('find_contact', { phone_number: '+7000' }, { tool_call_id: 'gemini-tool-1' });

  assert.equal(result.ok, false);
  assert.equal(result.fallback, true);
  assert.equal(result.pending, true);
  assert.equal(result.request_id, 'gemini-tool-1');
  assert.match(result.error, /timed out/);
  assert.deepEqual(controls.map((event) => event.action), ['tool_started', 'tool_failed']);
  assert.equal(controls[1].metadata.pending, true);
  assert.equal(toolPayloads[0].request_id, 'gemini-tool-1');

  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.deepEqual(controls.map((event) => event.action), ['tool_started', 'tool_failed', 'tool_async_completed']);
  assert.equal(controls[2].metadata.request_id, 'gemini-tool-1');
  assert.equal(controls[2].metadata.async, true);
});

test('ToolExecutor uses per-tool timeout when catalog provides one', async () => {
  const controls = [];
  const callOptions = [];
  const client = {
    sendControl: async (payload) => { controls.push(payload); return { status: 'ok' }; },
    callTool: async (_name, _payload, options) => { callOptions.push(options); return { ok: true }; }
  };
  const executor = new ToolExecutor({
    client,
    callRef: 'call-1',
    timeoutMs: 3_000,
    timeoutProvider: toolName => (toolName === 'faq_lookup' ? 6_000 : null)
  });

  const result = await executor.execute('faq_lookup', { query: 'refund' });

  assert.equal(result.ok, true);
  assert.equal(callOptions[0].timeoutMs, 6_000);
  assert.equal(controls[0].metadata.timeout_ms, 6_000);
});
