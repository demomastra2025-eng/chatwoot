const test = require('node:test');
const assert = require('node:assert/strict');
const {
  JanusSipServerProfileSession,
  normalizeServerProfile
} = require('../src/janus/server-runtime');

test('Janus server persists AI Pipecat start failure before hanging up the SIP call', async () => {
  const failures = [];
  const messages = [];
  let legacyCalls = 0;
  const error = new Error('old media server');
  error.code = 'media_server_ownership_controls_unavailable';
  const profile = normalizeServerProfile({
    id: 53,
    account_id: 530,
    inbox_id: 4865,
    number_ref: 'asterisk-analog-ai',
    provider: 'asterisk_analog',
    sip_username: 'ai-agent',
    sip_password: 'secret',
    sip_host: 'asterisk.test'
  });
  const session = new JanusSipServerProfileSession({
    app: {
      async routeInboundSafely() {
        return { action: 'ai', reason: 'voice_agent_sip_profile_route' };
      },
      async handleCall() { legacyCalls += 1; },
      async handleAiRuntimeStartFailure(payload) { failures.push(payload); }
    },
    profile,
    janusUrl: 'ws://janus.test/ws',
    mediaServerClient: {
      async ensureSessionOwnershipControls() { throw error; },
      async terminateSession() {}
    },
    WebSocketImpl: class {},
    runtimeMediaStreamFactory: async () => ({}),
    runtimeSelector: { select: () => 'pipecat' },
    pipecatClient: {
      isAvailable: () => true,
      async ensureAvailable() {},
      async preflightJanus() {},
      async attachJanus() { throw new Error('attach must not run'); }
    },
    logger: { log() {} }
  });
  session.sessionId = 100;
  session.client = {
    async pluginMessage(payload) { messages.push(payload); }
  };
  const handle = { id: 200, activeCallId: null };

  await session.handleIncomingCall({
    event: { jsep: { type: 'offer', sdp: 'v=0\r\noffer' } },
    result: { call_id: 'ai-failed-1', username: 'sip:+770****0000@asterisk.test' },
    handle
  });

  assert.equal(legacyCalls, 0);
  assert.equal(failures.length, 1);
  assert.equal(failures[0].requestPayload.routing.action, 'ai');
  assert.equal(failures[0].requestPayload.call_ref, 'asterisk_analog:janus-server:53:ai-failed-1');
  assert.equal(failures[0].error, error);
  assert.deepEqual(messages.map(message => message.body), [{ request: 'decline', code: 480 }]);
  assert.equal(handle.activeCallId, null);
});
