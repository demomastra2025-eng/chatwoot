const test = require('node:test');
const assert = require('node:assert/strict');
const { createHealthServer } = require('../src/diagnostics/health-server');

test('health server exposes runtime diagnostics', async () => {
  const health = createHealthServer({
    port: 0,
    diagnostics: () => ({ janus_server_runtime: { enabled: true, healthy_profiles: 2 } })
  });

  try {
    const server = await health.listen();
    const response = await fetch(`http://127.0.0.1:${server.address().port}/health`);
    const payload = await response.json();

    assert.equal(response.status, 200);
    assert.equal(payload.status, 'ok');
    assert.equal(payload.janus_server_runtime.healthy_profiles, 2);
  } finally {
    await health.close();
  }
});

test('health server rejects a bind failure instead of emitting an unhandled error', async () => {
  const first = createHealthServer({ port: 0 });
  const firstServer = await first.listen();
  const second = createHealthServer({ port: firstServer.address().port });

  try {
    await assert.rejects(() => second.listen(), error => error.code === 'EADDRINUSE');
  } finally {
    await second.close();
    await first.close();
  }
});
