const test = require('node:test');
const assert = require('node:assert/strict');
const { ToolExecutor } = require('../src/tools/tool-executor');

test('ToolExecutor wraps Rails tools with start/complete control events', async () => {
  const controls = [];
  const toolPayloads = [];
  const client = {
    sendControl: async payload => {
      controls.push(payload);
      return { status: 'ok' };
    },
    callTool: async (name, payload) => {
      toolPayloads.push(payload);
      return { tool: name, arguments: payload.arguments };
    },
  };
  const executor = new ToolExecutor({
    client,
    callRef: 'call-1',
    timeoutMs: 100,
    scopeProvider: () => ({ account_id: 42, number_ref: 'num-1' }),
  });

  const result = await executor.execute('find_contact', {
    phone_number: '+7000',
  });

  assert.deepEqual(result, {
    ok: true,
    result: { tool: 'find_contact', arguments: { phone_number: '+7000' } },
  });
  assert.deepEqual(
    controls.map(event => event.action),
    ['tool_started', 'tool_completed']
  );
  assert.equal(controls[0].metadata.tool_name, 'find_contact');
  assert.deepEqual(controls[0].metadata.input, { phone_number: '[REDACTED]' });
  assert.deepEqual(controls[1].metadata.output, {
    tool: 'find_contact',
    arguments: { phone_number: '[REDACTED]' },
  });
  assert.ok(controls.every(event => event.account_id === 42));
  assert.equal(toolPayloads[0].account_id, 42);
  assert.equal(toolPayloads[0].number_ref, 'num-1');
});

test('ToolExecutor redacts secrets in stringified trace payloads', async () => {
  const controls = [];
  const client = {
    sendControl: async payload => {
      controls.push(payload);
      return { status: 'ok' };
    },
    callTool: async () => ({
      body: '{"accessToken":"secret","visible":"ok"}',
      plain: 'password: "secret" token=abc123',
    }),
  };
  const executor = new ToolExecutor({ client, callRef: 'call-1', timeoutMs: 100 });

  await executor.execute('custom_tool', {
    body: '{"phone":"+77000000000","query":"цена"}',
  });

  assert.equal(
    controls[0].metadata.input.body,
    '{"phone":"[REDACTED]","query":"цена"}'
  );
  assert.equal(
    controls[1].metadata.output.body,
    '{"accessToken":"[REDACTED]","visible":"ok"}'
  );
  assert.equal(
    controls[1].metadata.output.plain,
    'password: [REDACTED] token=[REDACTED]'
  );
});

test('ToolExecutor converts timeout into fallback, keeps tool running, and emits async completion', async () => {
  const controls = [];
  const toolPayloads = [];
  const client = {
    sendControl: async payload => {
      controls.push(payload);
      return { status: 'ok' };
    },
    callTool: async (_name, payload) => {
      toolPayloads.push(payload);
      return new Promise(resolve => {
        setTimeout(() => resolve({ answer: 'late result' }), 30);
      });
    },
  };
  const executor = new ToolExecutor({
    client,
    callRef: 'call-1',
    timeoutMs: 5,
  });

  const result = await executor.execute(
    'find_contact',
    { phone_number: '+7000' },
    { tool_call_id: 'gemini-tool-1' }
  );

  assert.equal(result.ok, false);
  assert.equal(result.fallback, true);
  assert.equal(result.pending, true);
  assert.equal(result.request_id, 'gemini-tool-1');
  assert.match(result.error, /timed out/);
  assert.deepEqual(
    controls.map(event => event.action),
    ['tool_started', 'tool_failed']
  );
  assert.equal(controls[1].metadata.pending, true);
  assert.equal(toolPayloads[0].request_id, 'gemini-tool-1');

  await new Promise(resolve => {
    setTimeout(resolve, 40);
  });
  assert.deepEqual(
    controls.map(event => event.action),
    ['tool_started', 'tool_failed', 'tool_async_completed']
  );
  assert.equal(controls[2].metadata.request_id, 'gemini-tool-1');
  assert.equal(controls[2].metadata.async, true);
  assert.deepEqual(controls[2].metadata.input, { phone_number: '[REDACTED]' });
  assert.deepEqual(controls[2].metadata.output, { answer: 'late result' });
});

test('ToolExecutor reports late async tool result to runtime callback after foreground timeout', async () => {
  const controls = [];
  const lateResults = [];
  const client = {
    sendControl: async payload => {
      controls.push(payload);
      return { status: 'ok' };
    },
    callTool: async () =>
      new Promise(resolve => {
        setTimeout(() => resolve({ answer: 'late answer' }), 25);
      }),
  };
  const executor = new ToolExecutor({
    client,
    callRef: 'call-1',
    timeoutMs: 200,
  });

  const result = await executor.execute(
    'faq_lookup',
    { query: 'слоган' },
    {
      tool_call_id: 'gemini-tool-2',
      foreground_timeout_ms: 5,
      onAsyncResult: async payload => {
        lateResults.push(payload);
      },
    }
  );

  assert.equal(result.pending, true);
  assert.equal(result.request_id, 'gemini-tool-2');
  await new Promise(resolve => {
    setTimeout(resolve, 40);
  });

  assert.deepEqual(
    controls.map(event => event.action),
    ['tool_started', 'tool_failed', 'tool_async_completed']
  );
  assert.equal(lateResults.length, 1);
  assert.equal(lateResults[0].ok, true);
  assert.equal(lateResults[0].tool_name, 'faq_lookup');
  assert.equal(lateResults[0].request_id, 'gemini-tool-2');
  assert.deepEqual(lateResults[0].result, { answer: 'late answer' });
});

test('ToolExecutor does not double-persist events when control succeeds', async () => {
  const controls = [];
  const events = [];
  const client = {
    sendControl: async payload => {
      controls.push(payload);
      return { status: 'ok' };
    },
    callTool: async () => ({ ok: true }),
  };
  const executor = new ToolExecutor({
    client,
    callRef: 'call-1',
    timeoutMs: 100,
    eventSender: async (action, metadata) => {
      events.push({ action, metadata });
    },
  });

  const result = await executor.execute(
    'faq_lookup',
    { query: 'слоган' },
    { tool_call_id: 'tool-1' }
  );

  assert.equal(result.ok, true);
  assert.deepEqual(
    controls.map(event => event.action),
    ['tool_started', 'tool_completed']
  );
  assert.deepEqual(events, []);
});

test('ToolExecutor falls back to event persistence when control fails', async () => {
  const events = [];
  const client = {
    sendControl: async () => {
      throw new Error('control unavailable');
    },
    callTool: async () => ({ ok: true }),
  };
  const executor = new ToolExecutor({
    client,
    callRef: 'call-1',
    timeoutMs: 100,
    eventSender: async (action, metadata) => {
      events.push({ action, metadata });
    },
  });

  const result = await executor.execute(
    'faq_lookup',
    { query: 'слоган' },
    { tool_call_id: 'tool-1' }
  );

  assert.equal(result.ok, true);
  assert.deepEqual(
    events.map(event => event.action),
    ['tool_started', 'tool_completed']
  );
});

test('ToolExecutor uses per-tool timeout when catalog provides one', async () => {
  const controls = [];
  const callOptions = [];
  const client = {
    sendControl: async payload => {
      controls.push(payload);
      return { status: 'ok' };
    },
    callTool: async (_name, _payload, options) => {
      callOptions.push(options);
      return { ok: true };
    },
  };
  const executor = new ToolExecutor({
    client,
    callRef: 'call-1',
    timeoutMs: 3_000,
    timeoutProvider: toolName => (toolName === 'faq_lookup' ? 6_000 : null),
  });

  const result = await executor.execute('faq_lookup', { query: 'refund' });

  assert.equal(result.ok, true);
  assert.equal(callOptions[0].timeoutMs, 6_000);
  assert.equal(controls[0].metadata.timeout_ms, 6_000);
});
