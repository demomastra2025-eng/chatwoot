const test = require('node:test');
const assert = require('node:assert/strict');
const { ToolExecutor } = require('../src/tools/tool-executor');

test('ToolExecutor wraps Rails tools with start/complete control events', async () => {
  const controls = [];
  const client = {
    sendControl: async (payload) => { controls.push(payload); return { status: 'ok' }; },
    callTool: async (name, payload) => ({ tool: name, arguments: payload.arguments })
  };
  const executor = new ToolExecutor({ client, callRef: 'call-1', timeoutMs: 100 });

  const result = await executor.execute('find_contact', { phone_number: '+7000' });

  assert.deepEqual(result, { ok: true, result: { tool: 'find_contact', arguments: { phone_number: '+7000' } } });
  assert.deepEqual(controls.map((event) => event.action), ['tool_started', 'tool_completed']);
  assert.equal(controls[0].metadata.tool_name, 'find_contact');
});

test('ToolExecutor converts timeout/errors into bounded fallback results and emits tool_failed', async () => {
  const controls = [];
  const client = {
    sendControl: async (payload) => { controls.push(payload); return { status: 'ok' }; },
    callTool: async () => new Promise((resolve) => setTimeout(() => resolve({ unreachable: true }), 50))
  };
  const executor = new ToolExecutor({ client, callRef: 'call-1', timeoutMs: 5 });

  const result = await executor.execute('find_contact', { phone_number: '+7000' });

  assert.equal(result.ok, false);
  assert.equal(result.fallback, true);
  assert.match(result.error, /timed out/);
  assert.deepEqual(controls.map((event) => event.action), ['tool_started', 'tool_failed']);
});
