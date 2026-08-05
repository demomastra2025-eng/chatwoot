const test = require('node:test');
const assert = require('node:assert/strict');
const {
  JanusSipServerProfileSession,
  normalizeServerProfile
} = require('../src/janus/server-runtime');

test('Janus server hands a pre-answer Pipecat failure to the legacy AI runtime', async () => {
  const failures = [];
  const fallbacks = [];
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
      async prepareAiRuntimeFallback(payload) {
        fallbacks.push(payload);
        payload.requestPayload.runtime_engine = 'onelink-ai-voice-node';
        return payload.routeDecision;
      },
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

  assert.equal(legacyCalls, 1);
  assert.equal(fallbacks.length, 1);
  assert.equal(fallbacks[0].requestPayload.routing.action, 'ai');
  assert.equal(fallbacks[0].requestPayload.call_ref, 'asterisk_analog:janus-server:53:ai-failed-1');
  assert.equal(fallbacks[0].error, error);
  assert.equal(failures.length, 0);
  assert.deepEqual(messages, []);
  assert.equal(handle.activeCallId, 'ai-failed-1');
});

test('Janus server never changes runtime after SIP accept dispatch becomes ambiguous', async () => {
  const failures = [];
  let fallbackAttempts = 0;
  let legacyCalls = 0;
  const profile = normalizeServerProfile({
    id: 54,
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
      async routeInboundSafely() { return { action: 'ai', reason: 'voice_agent_sip_profile_route' }; },
      async handleCall() { legacyCalls += 1; },
      async prepareAiRuntimeFallback() { fallbackAttempts += 1; },
      async handleAiRuntimeStartFailure(payload) { failures.push(payload); }
    },
    profile,
    janusUrl: 'ws://janus.test/ws',
    mediaServerClient: {
      async createSession() {
        return { session_id: 'media-ambiguous-1', meta_sdp_answer: 'v=0\r\nanswer' };
      },
      async createRuntimeAgent() {
        return { runtime_session_id: 'runtime-ambiguous-1', stream_url: 'ws://media.test/runtime-ambiguous-1' };
      },
      async terminateSession() { return true; }
    },
    WebSocketImpl: class {},
    runtimeMediaStreamFactory: async () => ({}),
    runtimeSelector: { select: () => 'pipecat' },
    pipecatClient: {},
    logger: { log() {} }
  });
  session.startPipecatCall = async facade => facade.answer();
  session.sessionId = 100;
  const messages = [];
  session.client = {
    async pluginMessage(payload) {
      messages.push(payload);
      if (payload.body.request === 'accept') throw new Error('SIP accept outcome is ambiguous');
    }
  };
  const handle = { id: 200, activeCallId: null };

  await session.handleIncomingCall({
    event: { jsep: { type: 'offer', sdp: 'v=0\r\noffer' } },
    result: { call_id: 'ai-post-answer-failed-1', username: 'sip:+770****0000@asterisk.test' },
    handle
  });

  assert.equal(fallbackAttempts, 0);
  assert.equal(legacyCalls, 0);
  assert.equal(failures.length, 1);
  assert.deepEqual(messages.map(message => message.body.request), ['accept', 'hangup']);
  assert.equal(handle.activeCallId, null);
});
