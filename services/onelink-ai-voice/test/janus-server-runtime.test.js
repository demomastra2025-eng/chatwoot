const test = require('node:test');
const assert = require('node:assert/strict');
const {
  JanusMediaServerClient,
  JanusSipServerCallFacade,
  JanusSipServerProfileSession,
  JanusSipServerRuntimeManager,
  JanusWebSocketClient,
  normalizeServerProfile,
  parseServerProfilesJson
} = require('../src/janus/server-runtime');
const { applyJanusServerProviderUrls } = require('../src/index');
const { EventEmitter } = require('node:events');

test('normalizeServerProfile builds a voice-agent-only SIP contract', () => {
  const profile = normalizeServerProfile({
    id: 12,
    account_id: 42,
    inbox_id: 9,
    number_ref: 'sipuni-main',
    provider: 'sipuni',
    internal_extension: '9098',
    sip_username: 'ai-agent-9098',
    sip_password: 'secret',
    sip_host: 'sip.example.test',
    sip_transport: 'udp'
  });

  assert.equal(profile.sip_profile.profile_kind, 'voice_agent');
  assert.equal(profile.sip_profile.voice_agent, true);
  assert.equal(profile.sip.uri, 'sip:ai-agent-9098@sip.example.test');
  assert.equal(profile.sip.proxy, 'sip:sip.example.test:5060');
  assert.equal(profile.provider, 'sipuni');
});

test('normalizeServerProfile preserves Rails Beeline proxy and codec contract', () => {
  const profile = normalizeServerProfile({
    id: 13,
    account_id: 42,
    inbox_id: 10,
    number_ref: 'beeline-main',
    provider: 'beeline',
    internal_extension: '1001',
    sip_username: 'agent-1001',
    sip_password: 'secret',
    sip_host: 'tenant.cloudpbx.beeline.kz',
    sip_port: 5060,
    sip_transport: 'udp',
    sip_proxy: '46.227.186.231:6050',
    sip_codec: 'pcma'
  });

  assert.equal(profile.sip.uri, 'sip:agent-1001@tenant.cloudpbx.beeline.kz');
  assert.equal(profile.sip.proxy, 'sip:46.227.186.231:6050');
  assert.equal(profile.sip.codec, 'pcma');
  assert.equal(profile.provider, 'beeline');
});

test('parseServerProfilesJson returns an empty list on blank or invalid env values', () => {
  assert.deepEqual(parseServerProfilesJson(''), []);
  assert.deepEqual(parseServerProfilesJson('{broken'), []);
});

test('Janus media-server client serializes account_id as string', async () => {
  const requests = [];
  const client = new JanusMediaServerClient({
    baseUrl: 'http://media.test',
    token: 'token',
    fetchImpl: async (url, options) => {
      requests.push({ url, body: JSON.parse(options.body) });
      return {
        ok: true,
        text: async () => JSON.stringify({ session_id: 'media-1' })
      };
    }
  });

  await client.createSession({
    callId: 'call-1',
    accountId: 530,
    sdpOffer: 'v=0',
    iceServers: []
  });

  assert.equal(requests[0].body.account_id, '530');
  assert.equal(requests[0].body.direction, 'incoming');
});

test('Janus media-server client fails closed when ownership controls are not advertised', async () => {
  const requests = [];
  const client = new JanusMediaServerClient({
    baseUrl: 'http://media.test',
    token: 'token',
    fetchImpl: async (url, options) => {
      requests.push({ url, method: options.method });
      return {
        ok: true,
        text: async () => JSON.stringify({ status: 'ok' })
      };
    }
  });

  await assert.rejects(
    () => client.ensureSessionOwnershipControls(),
    error => error.code === 'media_server_ownership_controls_unavailable'
  );
  assert.deepEqual(requests, [{ url: 'http://media.test/health', method: 'GET' }]);
});

test('Janus media-server client accepts explicit ownership controls capability', async () => {
  const client = new JanusMediaServerClient({
    baseUrl: 'http://media.test',
    token: 'token',
    fetchImpl: async () => ({
      ok: true,
      text: async () => JSON.stringify({
        status: 'ok',
        capabilities: { session_ownership_controls: true }
      })
    })
  });

  await assert.doesNotReject(() => client.ensureSessionOwnershipControls());
});

test('Janus WebSocket client bounds connection setup time', async () => {
  class NeverOpeningSocket extends EventEmitter {
    static OPEN = 1;

    terminate() {
      this.terminated = true;
    }

    close() {}
  }

  const client = new JanusWebSocketClient({
    url: 'ws://janus.test/ws',
    WebSocketImpl: NeverOpeningSocket,
    connectTimeoutMs: 5
  });

  await assert.rejects(() => client.connect(), /connection timed out/);
  assert.equal(client.ws, null);
});

test('Janus server call facade answers through media-server and exposes runtime stream', async () => {
  const janusMessages = [];
  const mediaCalls = [];
  const profile = normalizeServerProfile({
    id: 12,
    account_id: 42,
    inbox_id: 9,
    number_ref: 'sipuni-main',
    provider: 'sipuni',
    phone_number: '+77001234567',
    internal_extension: '9098',
    sip_username: 'ai-agent-9098',
    sip_password: 'secret',
    sip_host: 'sip.example.test'
  });
  const facade = new JanusSipServerCallFacade({
    profile,
    providerCallId: 'provider-call-1',
    caller: 'sip:+77005550101@sip.example.test',
    janus: {
      sessionId: 100,
      handleId: 200,
      jsep: { type: 'offer', sdp: 'v=0\r\no=- janus-offer' },
      client: {
        async pluginMessage(payload) {
          janusMessages.push(payload);
          if (payload.body.request === 'hangup') {
            setImmediate(() => facade.handleJanusEvent('hangup'));
          }
          return { janus: 'ack' };
        }
      }
    },
    mediaServerClient: {
      async createSession(payload) {
        mediaCalls.push(['createSession', payload]);
        return { session_id: 'media-session-1', meta_sdp_answer: 'v=0\r\no=- pion-answer' };
      },
      async createRuntimeAgent(sessionId, payload) {
        mediaCalls.push(['createRuntimeAgent', sessionId, payload]);
        return {
          runtime_session_id: 'runtime-1',
          stream_url: 'ws://media-server/sessions/media-session-1/runtime-stream',
          stream_token: 't1',
          codec: 'pcm_s16le',
          input_sample_rate: 16000,
          output_sample_rate: 8000
        };
      },
      async terminateSession() {}
    },
    runtimeMediaStreamFactory: async ({ request }) => ({ streamRef: request.stream_ref, mediaSessionRef: request.media_session_ref })
  });

  assert.equal(facade.request.transport, 'janus_sip');
  assert.equal(facade.request.metadata.source, 'server_janus_sip');
  assert.equal(facade.request.metadata.browser_join_supported, false);

  assert.equal(await facade.answer(), true);
  const stream = await facade.stream();

  assert.equal(stream.streamRef, 'runtime-1');
  assert.equal(stream.mediaSessionRef, 'media-session-1');
  assert.equal(facade.request.runtime_stream.stream_url, 'ws://media-server/sessions/media-session-1/runtime-stream');
  assert.equal(facade.request.runtime_stream.stream_token, 't1');
  assert.deepEqual(mediaCalls[0], [
    'createSession',
    {
      callId: 'sipuni:janus-server:12:provider-call-1',
      accountId: 42,
      sdpOffer: 'v=0\r\no=- janus-offer',
      iceServers: [],
      direction: 'incoming'
    }
  ]);
  assert.deepEqual(janusMessages[0].body, { request: 'accept', autoaccept_reinvites: true });
  assert.deepEqual(janusMessages[0].jsep, { type: 'answer', sdp: 'v=0\r\no=- pion-answer' });
  facade.enableHangupConfirmation();
  const hangup = await facade.hangup();
  assert.deepEqual(janusMessages[1].body, { request: 'hangup' });
  assert.deepEqual(hangup, {
    accepted: true,
    confirmed: true,
    outcome: 'janus_hangup_event'
  });
});

test('Janus server call facade negotiates native offerless SIP INVITEs', async () => {
  const janusMessages = [];
  const mediaCalls = [];
  const facade = new JanusSipServerCallFacade({
    profile: normalizeServerProfile({
      id: 16,
      account_id: 42,
      inbox_id: 9,
      provider: 'asterisk_analog',
      sip_username: 'ai-agent',
      sip_password: 'secret',
      sip_host: 'asterisk.test'
    }),
    providerCallId: 'offerless-1',
    caller: 'sip:1001@asterisk.test',
    janus: {
      sessionId: 100,
      handleId: 200,
      jsep: null,
      client: {
        async pluginMessage(payload) {
          janusMessages.push(payload);
          return { janus: 'ack' };
        }
      }
    },
    mediaServerClient: {
      async createSession(payload) {
        mediaCalls.push(['createSession', payload]);
        return { session_id: 'media-offerless', meta_sdp_offer: 'v=0\r\no=- pion-offer' };
      },
      async createRuntimeAgent() {
        return {
          runtime_session_id: 'runtime-offerless',
          stream_url: 'ws://media.test/runtime-offerless',
          codec: 'pcm_s16le',
          input_sample_rate: 16000,
          output_sample_rate: 8000
        };
      },
      async setMetaAnswer(sessionId, sdpAnswer) {
        mediaCalls.push(['setMetaAnswer', sessionId, sdpAnswer]);
        return { status: 'connected' };
      },
      async terminateSession() {}
    },
    runtimeMediaStreamFactory: async () => ({})
  });

  const answer = facade.answer();
  while (janusMessages.length === 0) {
    // The media-server and runtime attach complete on promise turns.
    // eslint-disable-next-line no-await-in-loop
    await new Promise(resolve => setImmediate(resolve));
  }
  facade.handleJanusEvent('accepted', {}, {
    jsep: { type: 'answer', sdp: 'v=0\r\no=- remote-answer' }
  });

  await assert.doesNotReject(() => answer);
  assert.deepEqual(mediaCalls[0], [
    'createSession',
    {
      callId: 'asterisk_analog:janus-server:16:offerless-1',
      accountId: 42,
      sdpOffer: '',
      iceServers: [],
      direction: 'outgoing'
    }
  ]);
  assert.deepEqual(janusMessages[0].jsep, {
    type: 'offer',
    sdp: 'v=0\r\no=- pion-offer'
  });
  assert.deepEqual(mediaCalls[1], [
    'setMetaAnswer',
    'media-offerless',
    'v=0\r\no=- remote-answer'
  ]);
});

test('Janus server call facade buffers a transfer outcome received before the SIP REFER ack', async () => {
  const janusMessages = [];
  let acknowledgeTransfer;
  const facade = new JanusSipServerCallFacade({
    profile: normalizeServerProfile({
      id: 12,
      account_id: 42,
      inbox_id: 9,
      provider: 'sipuni',
      sip_username: 'ai-agent',
      sip_password: 'secret',
      sip_host: 'sip.example.test'
    }),
    providerCallId: 'provider-call-transfer',
    caller: 'sip:+77005550101@sip.example.test',
    janus: {
      sessionId: 100,
      handleId: 200,
      jsep: { type: 'offer', sdp: 'v=0' },
      client: {
        async pluginMessage(payload) {
          janusMessages.push(payload);
          return new Promise(resolve => { acknowledgeTransfer = resolve; });
        }
      }
    },
    mediaServerClient: { async terminateSession() {} },
    runtimeMediaStreamFactory: async () => ({})
  });

  const legPromise = facade.dial({ agent_aor: 'sip:1001@example.test' });
  facade.handleJanusEvent('notify', { content: 'SIP/2.0 200 OK' });
  acknowledgeTransfer({ janus: 'ack' });
  const leg = await legPromise;

  assert.deepEqual(janusMessages[0].body, {
    request: 'transfer',
    uri: 'sip:1001@example.test'
  });
  assert.equal(leg.terminalOutcome, 'answered');
});

test('Janus server call facade tears down media when runtime-agent setup fails', async () => {
  const terminated = [];
  const janusMessages = [];
  const facade = new JanusSipServerCallFacade({
    profile: normalizeServerProfile({
      id: 15,
      account_id: 42,
      inbox_id: 9,
      provider: 'binotel',
      sip_username: 'ai-agent',
      sip_password: 'secret',
      sip_host: 'sip.example.test'
    }),
    providerCallId: 'provider-call-failed-answer',
    caller: 'sip:+77005550101@sip.example.test',
    janus: {
      sessionId: 100,
      handleId: 200,
      jsep: { type: 'offer', sdp: 'v=0' },
      client: {
        async pluginMessage(payload) {
          janusMessages.push(payload);
        }
      }
    },
    mediaServerClient: {
      async createSession() {
        return { session_id: 'media-failed', meta_sdp_answer: 'v=0' };
      },
      async createRuntimeAgent() {
        return {};
      },
      async terminateSession(sessionId, reason) {
        terminated.push([sessionId, reason]);
      }
    },
    runtimeMediaStreamFactory: async () => ({}),
    hangupConfirmationTimeoutMs: 1,
    hangupReconciliationGraceMs: 1
  });

  await assert.rejects(() => facade.answer(), /invalid runtime-agent response/);
  facade.enableHangupConfirmation();
  const hangup = await facade.hangup();
  assert.deepEqual(janusMessages.map(message => message.body), [
    { request: 'decline', code: 480 },
    { request: 'decline', code: 480 }
  ]);
  assert.deepEqual(hangup, {
    accepted: true,
    confirmed: false,
    outcome: 'command_retried_after_confirmation_timeout'
  });
  facade.handleJanusEvent('hangup');
  assert.equal(facade.ended, true);
  assert.equal(facade.hangupConfirmationPending, false);
  assert.deepEqual(terminated, [['media-failed', 'janus_answer_failed']]);
});

test('Janus server call facade tears down a late media session after caller hangup', async () => {
  let resolveCreateSession;
  let runtimeAgentCalls = 0;
  const terminated = [];
  const janusMessages = [];
  const facade = new JanusSipServerCallFacade({
    profile: normalizeServerProfile({
      id: 19,
      account_id: 42,
      inbox_id: 9,
      provider: 'sipuni',
      sip_username: 'ai-agent',
      sip_password: 'secret',
      sip_host: 'sip.example.test'
    }),
    providerCallId: 'provider-call-late-answer',
    caller: 'sip:+770****0101@sip.example.test',
    janus: {
      sessionId: 100,
      handleId: 200,
      jsep: { type: 'offer', sdp: 'v=0' },
      client: {
        async pluginMessage(payload) {
          janusMessages.push(payload);
        }
      }
    },
    mediaServerClient: {
      createSession: async () => new Promise(resolve => { resolveCreateSession = resolve; }),
      async createRuntimeAgent() {
        runtimeAgentCalls += 1;
        return {};
      },
      async terminateSession(sessionId, reason) {
        terminated.push([sessionId, reason]);
      }
    },
    runtimeMediaStreamFactory: async () => ({})
  });

  const answer = facade.answer();
  facade.handleJanusEvent('hangup');
  resolveCreateSession({ session_id: 'media-late', meta_sdp_answer: 'v=0' });

  await assert.rejects(answer, /call ended/);
  assert.equal(runtimeAgentCalls, 0);
  assert.deepEqual(janusMessages, []);
  assert.deepEqual(terminated, [['media-late', 'janus_answer_failed']]);
});

test('Janus server profile hands a selected call to Pipecat with one prepared media stream', async () => {
  const order = [];
  const attached = [];
  let legacyCalls = 0;
  const profile = normalizeServerProfile({
    id: 16,
    account_id: 42,
    inbox_id: 9,
    provider: 'sipuni',
    sip_username: 'ai-agent',
    sip_password: 'secret',
    sip_host: 'sip.example.test'
  });
  const session = new JanusSipServerProfileSession({
    app: {
      async routeInboundSafely(request) {
        order.push('route');
        assert.equal(request.runtime_engine, 'pipecat');
        request.runtime_session_id = 'runtime-route-pipecat-1';
        return { action: 'ai', reason: 'rails_ai_route' };
      },
      async handleCall() { legacyCalls += 1; }
    },
    profile,
    janusUrl: 'ws://janus.test/ws',
    mediaServerClient: {
      async ensureSessionOwnershipControls() {
        order.push('media_capabilities');
      },
      async createSession(payload) {
        order.push('create_media');
        assert.equal(payload.recordingEnabled, false);
        assert.equal(payload.railsCallbacksEnabled, false);
        return { session_id: 'media-pipecat-1', meta_sdp_answer: 'v=0\r\nanswer' };
      },
      async createRuntimeAgent() {
        order.push('create_runtime');
        return {
          runtime_session_id: 'runtime-pipecat-1',
          stream_url: 'ws://media-server/sessions/runtime-pipecat-1/runtime-stream',
          stream_token: 'runtime-stream-token-1234567890',
          codec: 'pcm_s16le',
          input_sample_rate: 16000,
          output_sample_rate: 8000
        };
      },
      async terminateSession() {}
    },
    WebSocketImpl: class {},
    runtimeMediaStreamFactory: async () => ({}),
    runtimeSelector: {
      selectCandidate: () => 'pipecat',
      select: payload => {
        assert.equal(payload.runtime_engine, 'pipecat');
        return 'pipecat';
      }
    },
    pipecatClient: {
      isAvailable: () => true,
      async ensureAvailable() { order.push('ready'); },
      async preflightJanus(payload) {
        order.push('preflight');
        assert.equal(payload.call_ref, 'sipuni:janus-server:16:pipecat-1');
        assert.equal(payload.runtime_session_id, 'runtime-route-pipecat-1');
      },
      async attachJanus(payload) {
        order.push('attach');
        attached.push(payload);
        return { session_id: 'pipecat-session-1' };
      }
    },
    pipecatRuntimeControl: {
      register() {
        return {
          id: 'control-1',
          control_url: 'http://voice-runtime:8081/internal/pipecat/runtime-control/control-1',
          token: 'runtime-control-token-1234567890'
        };
      }
    },
    logger: { log() {} }
  });
  session.sessionId = 100;
  session.client = {
    async pluginMessage() { order.push('accept'); }
  };

  await session.handleIncomingCall({
    event: { jsep: { type: 'offer', sdp: 'v=0\r\noffer' } },
    result: { call_id: 'pipecat-1', username: 'sip:+77000000000@sip.example.test' },
    handle: { id: 200, activeCallId: null }
  });

  assert.equal(legacyCalls, 0);
  assert.deepEqual(order, ['route', 'ready', 'preflight', 'media_capabilities', 'create_media', 'create_runtime', 'accept', 'attach']);
  assert.equal(attached.length, 1);
  assert.equal(attached[0].runtime_session_id, 'runtime-route-pipecat-1');
  assert.equal(attached[0].runtime_stream.runtime_session_id, 'runtime-pipecat-1');
  assert.equal(attached[0].runtime_stream.output_sample_rate, 8000);
  assert.equal(attached[0].runtime_stream.stream_token, 'runtime-stream-token-1234567890');
  assert.equal(attached[0].runtime_control.control_url, 'http://voice-runtime:8081/internal/pipecat/runtime-control/control-1');
  assert.deepEqual(attached[0].routing, {
    action: 'ai',
    reason: 'rails_ai_route'
  });
});

test('Janus server Pipecat preflight failure happens before answering media', async () => {
  const order = [];
  const session = new JanusSipServerProfileSession({
    app: { async handleCall() {} },
    profile: normalizeServerProfile({
      id: 99,
      account_id: 42,
      inbox_id: 9,
      provider: 'sipuni',
      sip_username: 'ai-agent',
      sip_password: 'secret',
      sip_host: 'sip.example.test'
    }),
    janusUrl: 'ws://janus.test/ws',
    mediaServerClient: {},
    WebSocketImpl: class {},
    runtimeMediaStreamFactory: async () => ({}),
    runtimeSelector: { select: () => 'pipecat' },
    pipecatClient: {
      isAvailable: () => true,
      async ensureAvailable() { order.push('ready'); },
      async preflightJanus() {
        order.push('preflight');
        throw new Error('provider unavailable');
      },
      async attachJanus() { order.push('attach'); }
    },
    logger: { log() {} }
  });
  const facade = {
    request: { call_ref: 'sipuni:test', routing: { action: 'ai' } },
    async answer() { order.push('answer'); }
  };

  await assert.rejects(session.startPipecatCall(facade), /provider unavailable/);

  assert.deepEqual(order, ['ready', 'preflight']);
});

test('Janus server media ownership capability failure happens before answering media', async () => {
  const order = [];
  const session = new JanusSipServerProfileSession({
    app: { async handleCall() {} },
    profile: normalizeServerProfile({
      id: 100,
      account_id: 42,
      inbox_id: 9,
      provider: 'sipuni',
      sip_username: 'ai-agent',
      sip_password: 'secret',
      sip_host: 'sip.example.test'
    }),
    janusUrl: 'ws://janus.test/ws',
    mediaServerClient: {},
    WebSocketImpl: class {},
    runtimeMediaStreamFactory: async () => ({}),
    runtimeSelector: { select: () => 'pipecat' },
    pipecatClient: {
      isAvailable: () => true,
      async ensureAvailable() { order.push('ready'); },
      async preflightJanus() { order.push('preflight'); },
      async attachJanus() { order.push('attach'); }
    },
    logger: { log() {} }
  });
  const facade = {
    request: { call_ref: 'sipuni:test', routing: { action: 'ai' } },
    mediaServerClient: {
      async ensureSessionOwnershipControls() {
        order.push('media_capabilities');
        const error = new Error('old media server');
        error.code = 'media_server_ownership_controls_unavailable';
        throw error;
      }
    },
    async answer() { order.push('answer'); }
  };

  await assert.rejects(
    () => session.startPipecatCall(facade),
    error => error.code === 'media_server_ownership_controls_unavailable'
  );
  assert.deepEqual(order, ['ready', 'preflight', 'media_capabilities']);
});

test('Janus server keeps Rails operator decisions on the native call facade', async () => {
  const messages = [];
  let handledCall = null;
  const profile = normalizeServerProfile({
    id: 16,
    account_id: 42,
    inbox_id: 9,
    provider: 'asterisk_analog',
    sip_username: 'ai-agent',
    sip_password: 'secret',
    sip_host: 'asterisk.test'
  });
  const session = new JanusSipServerProfileSession({
    app: {
      async routeInboundSafely() {
        return {
          action: 'operator',
          reason: 'routing_policy_operator',
          operator: { agent_aor: 'sip:operator@example.test' }
        };
      },
      async handleCall(call) { handledCall = call; }
    },
    profile,
    janusUrl: 'ws://janus.test/ws',
    mediaServerClient: {},
    WebSocketImpl: class {},
    runtimeMediaStreamFactory: async () => ({}),
    runtimeSelector: {
      select(payload) {
        assert.equal(payload.routing.action, 'operator');
        return payload.routing.action === 'ai' ? 'pipecat' : 'legacy';
      }
    },
    pipecatClient: {
      async preflightJanus() { throw new Error('operator route reached Pipecat'); }
    },
    hangupConfirmationTimeoutMs: 1,
    hangupReconciliationGraceMs: 1,
    maxCalls: 1,
    logger: { log() {} }
  });
  session.sessionId = 100;
  session.client = {
    async pluginMessage(payload) {
      messages.push(payload);
    }
  };

  await session.handleIncomingCall({
    event: {},
    result: { call_id: 'offerless-1' },
    handle: { id: 200, activeCallId: null }
  });

  assert.ok(handledCall);
  assert.equal(handledCall.request.call_ref, 'asterisk_analog:janus-server:16:offerless-1');
  assert.deepEqual(handledCall.request.routing, {
    action: 'operator',
    reason: 'routing_policy_operator',
    operator: { agent_aor: 'sip:operator@example.test' }
  });
  assert.equal(handledCall.janus.jsep, undefined);
  assert.deepEqual(messages, []);
  assert.equal(handledCall.hangupConfirmationRequired, false);
  handledCall.answered = true;
  assert.equal(await handledCall.hangup(), true);
  assert.deepEqual(messages.map(message => message.body), [
    { request: 'hangup' }
  ]);
  assert.equal(handledCall.ended, true);
});

test('Janus server profile close rejects pending SIP registration waiters', async () => {
  const session = new JanusSipServerProfileSession({
    app: { async handleCall() {} },
    profile: normalizeServerProfile({
      id: 17,
      account_id: 42,
      inbox_id: 9,
      provider: 'sipuni',
      sip_username: 'ai-agent',
      sip_password: 'secret',
      sip_host: 'sip.example.test'
    }),
    janusUrl: 'ws://janus.test/ws',
    mediaServerClient: {},
    WebSocketImpl: class {},
    runtimeMediaStreamFactory: async () => ({}),
    maxCalls: 1,
    logger: { log() {} }
  });
  session.client = { close() {} };
  const registration = session.waitForRegistration(20000);

  await session.close();

  await assert.rejects(registration, /profile session closed/);
  assert.equal(session.registrationWaiters.size, 0);
});

test('Janus server socket close rejects pending SIP registration waiters immediately', async () => {
  const session = new JanusSipServerProfileSession({
    app: { async handleCall() {} },
    profile: normalizeServerProfile({
      id: 18,
      account_id: 42,
      inbox_id: 9,
      provider: 'sipuni',
      sip_username: 'ai-agent',
      sip_password: 'secret',
      sip_host: 'sip.example.test'
    }),
    janusUrl: 'ws://janus.test/ws',
    mediaServerClient: {},
    WebSocketImpl: class {},
    runtimeMediaStreamFactory: async () => ({}),
    maxCalls: 1,
    logger: { log() {} }
  });
  const registration = session.waitForRegistration(20000);

  session.handleSocketClose();

  await assert.rejects(registration, /websocket closed/);
  assert.equal(session.registrationWaiters.size, 0);
});

test('Janus server helper recovery runs another pass when dirtied in flight', async () => {
  const session = new JanusSipServerProfileSession({
    app: { async handleCall() {} },
    profile: normalizeServerProfile({
      id: 20,
      account_id: 42,
      inbox_id: 9,
      provider: 'sipuni',
      sip_username: 'ai-agent',
      sip_password: 'secret',
      sip_host: 'sip.example.test'
    }),
    janusUrl: 'ws://janus.test/ws',
    mediaServerClient: {},
    WebSocketImpl: class {},
    runtimeMediaStreamFactory: async () => ({}),
    maxCalls: 2,
    logger: { log() {} }
  });
  session.client.ws = {};
  let recoveryPasses = 0;
  let releaseFirstPass;
  const firstPassBlocked = new Promise(resolve => { releaseFirstPass = resolve; });
  session.performEnsureDesiredHandles = async () => {
    recoveryPasses += 1;
    if (recoveryPasses === 1) await firstPassBlocked;
  };

  const firstRecovery = session.ensureDesiredHandles();
  const secondRecovery = session.ensureDesiredHandles();
  releaseFirstPass();
  await Promise.all([firstRecovery, secondRecovery]);

  assert.equal(recoveryPasses, 2);
});

test('Janus server runtime syncs profiles from provider and unregisters removed profiles', async () => {
  let providerProfiles = [
    {
      id: 12,
      version: 'v1',
      account_id: 42,
      inbox_id: 9,
      provider: 'sipuni',
      internal_extension: '9098',
      sip_username: 'ai-agent-9098',
      sip_password: 'secret',
      sip_host: 'sip.example.test'
    }
  ];
  const sockets = [];
  const manager = new JanusSipServerRuntimeManager({
    app: { async handleCall() {} },
    janusUrl: 'ws://janus.test/ws',
    syncIntervalMs: 0,
    profileProvider: async () => providerProfiles,
    maxCallsPerProfile: 3,
    mediaServerClient: {},
    WebSocketImpl: class FakeJanusSocket extends EventEmitter {
      constructor() {
        super();
        this.closed = false;
        this.registerMessages = [];
        this.nextHandleId = 200;
        sockets.push(this);
        setImmediate(() => this.emit('open'));
      }

      send(raw) {
        const payload = JSON.parse(raw);
        const response = { janus: 'success', transaction: payload.transaction };
        if (payload.janus === 'create') response.data = { id: 100 + sockets.length };
        if (payload.janus === 'attach') response.data = { id: ++this.nextHandleId };
        if (payload.body?.request === 'register') this.registerMessages.push(payload.body);
        setImmediate(() => this.emit('message', JSON.stringify(response)));
        if (payload.body?.request === 'register') {
          setImmediate(() => this.emit('message', JSON.stringify({
            janus: 'event',
            session_id: payload.session_id,
            sender: payload.handle_id,
            plugindata: {
              plugin: 'janus.plugin.sip',
              data: { result: { event: 'registered', username: payload.body.username, master_id: 900 + sockets.length } }
            }
          })));
        }
        if (payload.body?.request === 'unregister') {
          setImmediate(() => this.emit('message', JSON.stringify({
            janus: 'event',
            session_id: payload.session_id,
            sender: payload.handle_id,
            plugindata: {
              plugin: 'janus.plugin.sip',
              data: { result: { event: 'unregistered' } }
            }
          })));
        }
      }

      close() {
        this.closed = true;
        this.emit('close');
      }
    }
  });

  await manager.start();
  assert.equal(manager.sessions.size, 1);
  assert.equal(sockets[0].registerMessages[0].username, 'sip:ai-agent-9098@sip.example.test');
  assert.equal(sockets[0].registerMessages.length, 3);
  assert.deepEqual(sockets[0].registerMessages[1], {
    request: 'register',
    type: 'helper',
    username: 'sip:ai-agent-9098@sip.example.test',
    master_id: 901
  });

  providerProfiles = [{ ...providerProfiles[0], app_ref: 'updated-runtime', routing_mode: 'ai' }];
  const healthySession = manager.sessions.get('12');
  const helperKey = Array.from(healthySession.handles.keys()).find(key => key !== String(healthySession.handleId));
  sockets[0].emit('message', JSON.stringify({
    janus: 'detached',
    session_id: healthySession.sessionId,
    sender: Number(helperKey)
  }));
  for (let index = 0; index < 5; index += 1) {
    await new Promise(resolve => setImmediate(resolve));
  }
  await manager.syncProfiles();
  assert.equal(sockets.length, 1);
  assert.equal(manager.sessions.get('12').profile.app_ref, 'updated-runtime');
  assert.equal(manager.sessions.get('12').handles.size, 3);
  assert.equal(sockets[0].registerMessages.length, 4);

  providerProfiles = [{ ...providerProfiles[0], version: 'v2', app_ref: 'updated-runtime', sip_username: 'ai-agent-9099' }];
  await manager.syncProfiles();
  assert.equal(manager.sessions.size, 1);
  assert.equal(sockets[0].closed, true);
  assert.equal(sockets[1].registerMessages[0].username, 'sip:ai-agent-9099@sip.example.test');

  sockets[1].emit('close');
  await manager.syncProfiles();
  assert.equal(manager.sessions.size, 1);
  assert.equal(sockets.length, 3);
  assert.equal(sockets[2].registerMessages[0].username, 'sip:ai-agent-9099@sip.example.test');

  providerProfiles = [];
  await manager.syncProfiles();
  assert.equal(manager.sessions.size, 0);
  assert.equal(sockets[2].closed, true);
});

test('Janus server profile sync backs off after failures and resets after success', async () => {
  let shouldFail = true;
  const manager = new JanusSipServerRuntimeManager({
    app: { async handleCall() {} },
    mediaServerClient: {},
    syncIntervalMs: 1000,
    profileProvider: async () => {
      if (shouldFail) throw new Error('temporary profile endpoint timeout');
      return [];
    }
  });

  assert.equal(manager.profileSyncDelayMs(), 1000);
  await assert.rejects(() => manager.syncProfiles(), /temporary profile endpoint timeout/);
  assert.equal(manager.profileSyncDelayMs(), 2000);
  await assert.rejects(() => manager.syncProfiles(), /temporary profile endpoint timeout/);
  assert.equal(manager.profileSyncDelayMs(), 4000);
  assert.equal(manager.diagnostics().consecutive_sync_failures, 2);

  shouldFail = false;
  await manager.syncProfiles();
  assert.equal(manager.profileSyncDelayMs(), 1000);
  assert.equal(manager.diagnostics().consecutive_sync_failures, 0);
});

test('Janus server runtime applies provider-specific Janus WebSocket URLs', () => {
  const profiles = applyJanusServerProviderUrls([
    { id: 1, provider: 'sipuni' },
    { id: 2, provider: 'binotel' },
    { id: 3, provider: 'asterisk_analog' },
    { id: 4, provider: 'beeline' },
    { id: 5, provider: 'custom' }
  ], {
    janusServerWsUrl: 'ws://janus-default:8188',
    janusServerProviderWsUrls: {
      sipuni: 'ws://janus-sipuni:8188',
      binotel: 'ws://janus-binotel:8188',
      asterisk_analog: 'ws://janus-asterisk:8189',
      beeline: 'ws://janus-beeline:8188'
    }
  });

  assert.equal(profiles[0].janus_url, 'ws://janus-sipuni:8188');
  assert.equal(profiles[1].janus_url, 'ws://janus-binotel:8188');
  assert.equal(profiles[2].janus_url, 'ws://janus-asterisk:8189');
  assert.equal(profiles[3].janus_url, 'ws://janus-beeline:8188');
  assert.equal(profiles[4].janus_url, 'ws://janus-default:8188');
});
