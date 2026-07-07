const assert = require('node:assert/strict');
const test = require('node:test');

const { JanusAdminClient, normalizeAdminBaseUrl } = require('../src/janus/admin-client');

test('normalizeAdminBaseUrl appends /admin only when needed', () => {
  assert.equal(normalizeAdminBaseUrl('http://janus:7088'), 'http://janus:7088/admin');
  assert.equal(normalizeAdminBaseUrl('http://janus:7088/admin'), 'http://janus:7088/admin');
  assert.equal(normalizeAdminBaseUrl(''), '');
});

test('JanusAdminClient sends SIP plugin messages through Admin API', async () => {
  const calls = [];
  const client = new JanusAdminClient({
    baseUrl: 'http://janus:7088',
    adminSecret: 'admin-secret',
    transactionPrefix: 'test',
    fetchImpl: async (url, options) => {
      calls.push({ url, options, body: JSON.parse(options.body) });
      return {
        ok: true,
        status: 200,
        async text() {
          return JSON.stringify({
            janus: 'success',
            response: { event: 'forwarders', rtp_forwarders: [] }
          });
        }
      };
    }
  });

  const response = await client.messagePlugin({
    sessionId: '123',
    handleId: '456',
    request: { request: 'listforwarders', unique_id: 'sip-unique-1' }
  });

  assert.deepEqual(response, { event: 'forwarders', rtp_forwarders: [] });
  assert.equal(calls[0].url, 'http://janus:7088/admin');
  assert.equal(calls[0].body.janus, 'message_plugin');
  assert.equal(calls[0].body.plugin, 'janus.plugin.sip');
  assert.equal(calls[0].body.admin_secret, 'admin-secret');
  assert.equal(calls[0].body.session_id, undefined);
  assert.equal(calls[0].body.handle_id, undefined);
  assert.deepEqual(calls[0].body.request, { request: 'listforwarders', unique_id: 'sip-unique-1' });
});

test('JanusAdminClient can address a specific handle when explicitly requested', async () => {
  const calls = [];
  const client = new JanusAdminClient({
    baseUrl: 'http://janus:7088/admin',
    fetchImpl: async (url, options) => {
      calls.push({ url, body: JSON.parse(options.body) });
      return {
        ok: true,
        status: 200,
        async text() {
          return JSON.stringify({ janus: 'success', response: {} });
        }
      };
    }
  });

  await client.messagePlugin({
    sessionId: '123',
    handleId: '456',
    addressHandle: true,
    request: { request: 'listforwarders', unique_id: 'sip-unique-1' }
  });

  assert.equal(calls[0].url, 'http://janus:7088/admin/123/456');
  assert.equal(calls[0].body.session_id, 123);
  assert.equal(calls[0].body.handle_id, 456);
});
