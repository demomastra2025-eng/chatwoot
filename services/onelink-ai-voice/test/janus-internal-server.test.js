const test = require('node:test');
const assert = require('node:assert/strict');
const { createJanusInternalHandler } = require('../src/janus/internal-server');

function fakeReq({ method = 'POST', url = '/internal/janus-sip/calls', token = 'voice-secret', body = {} } = {}) {
  const listeners = {};
  return {
    method,
    url,
    headers: token === null ? {} : { authorization: `Bearer ${token}` },
    on(event, handler) { listeners[event] = handler; return this; },
    emitBody() {
      listeners.data?.(Buffer.from(JSON.stringify(body)));
      listeners.end?.();
    }
  };
}

function fakeRes() {
  return {
    statusCode: 200,
    headers: {},
    chunks: [],
    setHeader(name, value) { this.headers[name.toLowerCase()] = value; },
    end(chunk = '') { if (chunk) this.chunks.push(Buffer.from(chunk)); this.ended = true; this.emit?.('finish'); },
    json() { return JSON.parse(Buffer.concat(this.chunks).toString('utf8') || '{}'); }
  };
}

async function dispatch(handler, req, res) {
  const done = new Promise(resolve => { res.emit = resolve; });
  const handled = handler(req, res);
  req.emitBody?.();
  await done;
  return handled;
}

function voiceAgentSipProfile() {
  return {
    id: 12,
    profile_kind: 'voice_agent',
    voice_agent: true,
    internal_extension: '9098',
    sip_username: 'ai-agent-9098'
  };
}

test('Janus internal attach endpoint starts the current voice app with Janus runtime stream metadata', async () => {
  let handled;
  const app = {
    async handleCall(call, payload) {
      handled = { call, payload };
      assert.equal(await call.answer(), true);
      return { mode: 'realtime', session: { callRef: payload.call_ref }, completion: Promise.resolve() };
    }
  };
  const handler = createJanusInternalHandler({ app, internalToken: 'voice-secret' });
  const body = {
    call_ref: 'sipuni:janus-ai:call-1',
    bridge_call_ref: 'sipuni:janus:operator-safe-ref',
    account_id: '42',
    inbox_id: '9',
    conversation_id: '7',
    provider: 'sipuni',
    sip_profile: voiceAgentSipProfile(),
    runtime_stream: {
      runtime_session_id: 'janus-rt-1',
      stream_url: 'ws://janus-ai-gateway/sessions/janus-rt-1/runtime-stream',
      stream_token: 't1',
      codec: 'pcm_s16le',
      input_sample_rate: 16000,
      output_sample_rate: 8000
    },
    janus: {
      session_id: 'janus-session-1',
      handle_id: 'janus-handle-1'
    },
    routing: { action: 'ai', reason: 'pending_conversation_ai_route' }
  };

  const req = fakeReq({ body });
  const res = fakeRes();
  const handledRoute = await dispatch(handler, req, res);

  assert.equal(handledRoute, true);
  assert.equal(res.statusCode, 202);
  assert.deepEqual(res.json(), {
    status: 'accepted',
    mode: 'accepted',
    call_ref: 'sipuni:janus-ai:call-1',
    transport: 'janus_sip'
  });
  assert.equal(handled.payload.transport, 'janus_sip');
  assert.equal(handled.payload.provider, 'sipuni');
  assert.equal(handled.payload.bridge_call_ref, 'sipuni:janus:operator-safe-ref');
  assert.equal(handled.payload.runtime_stream.stream_url, body.runtime_stream.stream_url);
  assert.equal(handled.call.request.janus.plugin, 'janus.plugin.sip');
});

test('Janus internal attach endpoint starts RTP forwarders only when explicitly requested', async () => {
  let handled;
  const rtpCalls = [];
  const app = {
    async handleCall(call, payload) {
      handled = { call, payload };
      return { mode: 'realtime', session: { callRef: payload.call_ref }, completion: Promise.resolve() };
    }
  };
  const rtpForwardController = {
    async startForwarders(payload) {
      rtpCalls.push(payload);
      return { forwarders: [{ stream_id: 1001, type: 'peer_audio' }] };
    }
  };
  const handler = createJanusInternalHandler({ app, internalToken: 'voice-secret', rtpForwardController });

  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:call-2',
      routing: { action: 'ai' },
      sip_profile: voiceAgentSipProfile(),
      janus: {
        unique_id: 'sip-handle-unique',
        session_id: '123',
        handle_id: '456',
        rtp_forward: {
          enabled: true,
          streams: [{ type: 'peer_audio', host: 'janus-ai-gateway', port: 40000 }]
        }
      },
      runtime_stream: {
        runtime_session_id: 'janus-rt-2',
        stream_url: 'ws://janus-ai-gateway/sessions/janus-rt-2/runtime-stream',
        stream_token: 't2'
      }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 202);
  assert.equal(rtpCalls.length, 1);
  assert.deepEqual(rtpCalls[0], {
    uniqueId: 'sip-handle-unique',
    sessionId: '123',
    handleId: '456',
    streams: [{ type: 'peer_audio', host: 'janus-ai-gateway', port: 40000 }]
  });
  assert.deepEqual(handled.payload.janus.rtp_forward_result, {
    forwarders: [{ stream_id: 1001, type: 'peer_audio' }]
  });
});

test('Janus internal attach endpoint can create an in-process RTP bridge runtime stream', async () => {
  let handled;
  const app = {
    async handleCall(call, payload) {
      handled = { call, payload };
      return { mode: 'realtime', session: { callRef: payload.call_ref }, completion: Promise.resolve() };
    }
  };
  const rtpBridgeManager = {
    async createSession(payload) {
      assert.equal(payload.callRef, 'sipuni:janus-ai:call-bridge');
      return {
        id: 'janus-rtp-session-1',
        inboundSsrc: 123456,
        streamRef: 'janus-rtp-session-1',
        mediaSessionRef: 'janus-rtp-session-1'
      };
    },
    forwardStreamsForSession(session) {
      return [{ type: 'peer_audio', host: 'onelink_ai_voice', port: 40000, ssrc: session.inboundSsrc }];
    }
  };
  const rtpForwardController = {
    async startForwarders(payload) {
      return { forwarders: payload.streams.map((stream, index) => ({ ...stream, stream_id: 1000 + index })) };
    }
  };
  const handler = createJanusInternalHandler({
    app,
    internalToken: 'voice-secret',
    rtpBridgeManager,
    rtpForwardController
  });
  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:call-bridge',
      routing: { action: 'ai' },
      sip_profile: voiceAgentSipProfile(),
      janus: {
        unique_id: 'sip-handle-bridge',
        rtp_bridge: { enabled: true },
        rtp_forward: { enabled: true }
      }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 202);
  assert.equal(handled.payload.runtime_stream.kind, 'janus_rtp_bridge');
  assert.equal(handled.payload.runtime_stream.runtime_session_id, 'janus-rtp-session-1');
  assert.deepEqual(handled.payload.janus.rtp_forward.streams, [
    { type: 'peer_audio', host: 'onelink_ai_voice', port: 40000, ssrc: 123456 }
  ]);
  assert.equal(handled.payload.janus.rtp_bridge_result.inbound_ssrc, 123456);
});

test('Janus internal attach endpoint can create a browser Janus media bridge runtime stream', async () => {
  let handled;
  const app = {
    async handleCall(call, payload) {
      handled = { call, payload };
      return { mode: 'realtime', session: { callRef: payload.call_ref }, completion: Promise.resolve() };
    }
  };
  const browserBridgeManager = {
    createSession(payload) {
      assert.equal(payload.callRef, 'sipuni:janus-ai:call-browser');
      return {
        id: 'janus-browser-session-1',
        streamRef: 'janus-browser-stream-1',
        mediaSessionRef: 'janus-browser-media-1'
      };
    },
    streamUrlForSession(session) {
      return `wss://dev.one-link.kz/ai-voice/janus-sip/browser-media/${session.id}/t1`;
    }
  };
  const handler = createJanusInternalHandler({
    app,
    internalToken: 'voice-secret',
    browserBridgeManager
  });
  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:call-browser',
      routing: { action: 'ai' },
      sip_profile: voiceAgentSipProfile(),
      janus: {
        browser_bridge: { enabled: true }
      }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 202);
  assert.deepEqual(res.json().browser_bridge, {
    runtime_session_id: 'janus-browser-session-1',
    stream_ref: 'janus-browser-stream-1',
    media_session_ref: 'janus-browser-media-1',
    stream_url: 'wss://dev.one-link.kz/ai-voice/janus-sip/browser-media/janus-browser-session-1/t1'
  });
  assert.equal(handled.payload.runtime_stream.kind, 'browser_janus_bridge');
  assert.equal(handled.payload.runtime_stream.runtime_session_id, 'janus-browser-session-1');
  assert.equal(handled.payload.runtime_stream.input_mime_type, 'audio/pcm;rate=16000');
  assert.equal(handled.payload.runtime_stream.output_mime_type, 'audio/pcm;rate=8000');
});

test('Janus internal attach endpoint fails closed when RTP forward is requested without controller', async () => {
  const handler = createJanusInternalHandler({
    app: { handleCall: async () => { throw new Error('must not run'); } },
    internalToken: 'voice-secret'
  });
  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:call-3',
      routing: { action: 'ai' },
      sip_profile: voiceAgentSipProfile(),
      janus: {
        unique_id: 'sip-handle-unique',
        rtp_forward: { enabled: true }
      }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 502);
  assert.equal(res.json().error, 'janus_rtp_forward_unavailable');
});

test('Janus internal attach endpoint requires a voice-agent SIP profile contract', async () => {
  let called = false;
  const handler = createJanusInternalHandler({
    app: { handleCall: async () => { called = true; } },
    internalToken: 'voice-secret'
  });
  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:human-profile',
      provider: 'sipuni',
      sip_profile: {
        id: 13,
        profile_kind: 'human_operator',
        voice_agent: false
      }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(called, false);
  assert.equal(res.statusCode, 422);
  assert.equal(res.json().error, 'voice_agent_sip_profile_required');
});

test('Janus internal attach endpoint can be limited to Sipuni only', async () => {
  let called = false;
  const handler = createJanusInternalHandler({
    app: { handleCall: async () => { called = true; } },
    internalToken: 'voice-secret',
    allowedProviders: ['sipuni']
  });
  const req = fakeReq({
    body: {
      call_ref: 'binotel:janus-ai:call-1',
      provider: 'binotel'
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(called, false);
  assert.equal(res.statusCode, 422);
  assert.deepEqual(res.json(), {
    error: 'provider_not_allowed',
    provider: 'binotel',
    allowed_providers: ['sipuni']
  });
});

test('Janus internal attach fails closed when Pipecat is selected without server-side media ownership', async () => {
  let legacyCalls = 0;
  let pipecatCalls = 0;
  let bridgeCalls = 0;
  const handler = createJanusInternalHandler({
    app: { handleCall: async () => { legacyCalls += 1; } },
    internalToken: 'voice-secret',
    runtimeSelector: { select: () => 'pipecat' },
    pipecatClient: {
      async attachJanus() { pipecatCalls += 1; }
    },
    browserBridgeManager: {
      async createSession() { bridgeCalls += 1; }
    }
  });
  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:pipecat-1',
      account_id: '42',
      inbox_id: '9',
      provider: 'sipuni',
      sip_profile: voiceAgentSipProfile(),
      routing: { action: 'ai' }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 503);
  assert.equal(res.json().error, 'pipecat_internal_janus_unsupported');
  assert.equal(legacyCalls, 0);
  assert.equal(pipecatCalls, 0);
  assert.equal(bridgeCalls, 0);
});

test('Janus internal attach rejects non-AI routes before starting either consumer', async () => {
  let runtimeSelections = 0;
  let legacyCalls = 0;
  const handler = createJanusInternalHandler({
    app: { handleCall: async () => { legacyCalls += 1; } },
    internalToken: 'voice-secret',
    runtimeSelector: { select: () => { runtimeSelections += 1; return 'pipecat'; } },
    pipecatClient: { attachJanus: async () => { throw new Error('must not run'); } }
  });
  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:operator-route',
      sip_profile: voiceAgentSipProfile(),
      routing: { action: 'operator' }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 422);
  assert.equal(res.json().error, 'non_ai_route_not_supported');
  assert.equal(runtimeSelections, 0);
  assert.equal(legacyCalls, 0);
});

test('Janus internal attach rejects a missing routing action before selecting a runtime', async () => {
  let runtimeSelections = 0;
  const handler = createJanusInternalHandler({
    app: { handleCall: async () => { throw new Error('must not run'); } },
    internalToken: 'voice-secret',
    runtimeSelector: { select: () => { runtimeSelections += 1; return 'pipecat'; } },
    pipecatClient: { attachJanus: async () => { throw new Error('must not run'); } }
  });
  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:missing-route',
      sip_profile: voiceAgentSipProfile()
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 422);
  assert.equal(res.json().error, 'ai_route_required');
  assert.equal(runtimeSelections, 0);
});

test('Janus Pipecat availability fence runs before RTP bridge side effects', async () => {
  let bridgeCalls = 0;
  const handler = createJanusInternalHandler({
    app: { handleCall: async () => { throw new Error('must not run'); } },
    internalToken: 'voice-secret',
    runtimeSelector: { select: () => 'pipecat' },
    pipecatClient: {
      isAvailable: () => false,
      attachJanus: async () => { throw new Error('must not run'); }
    },
    rtpBridgeManager: {
      async createSession() {
        bridgeCalls += 1;
        throw new Error('must not run');
      }
    }
  });
  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:pipecat-unavailable',
      account_id: '42',
      provider: 'sipuni',
      sip_profile: voiceAgentSipProfile(),
      routing: { action: 'ai' },
      janus: { rtp_bridge: { enabled: true } }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 503);
  assert.equal(res.json().error, 'pipecat_internal_janus_unsupported');
  assert.equal(bridgeCalls, 0);
});

test('Janus Pipecat selection requires its dedicated browser bridge without RTP side effects', async () => {
  let bridgeCalls = 0;
  const handler = createJanusInternalHandler({
    app: { handleCall: async () => { throw new Error('must not run'); } },
    internalToken: 'voice-secret',
    runtimeSelector: { select: () => 'pipecat' },
    pipecatClient: {
      isAvailable: () => true,
      attachJanus: async () => { throw new Error('must not run'); }
    },
    rtpBridgeManager: {
      createSession: async () => { bridgeCalls += 1; }
    }
  });
  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:missing-stream',
      sip_profile: voiceAgentSipProfile(),
      routing: { action: 'ai' },
      janus: { rtp_bridge: { enabled: true } }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 503);
  assert.equal(res.json().error, 'pipecat_internal_janus_unsupported');
  assert.equal(bridgeCalls, 0);
});

test('Janus legacy attach rolls back bridge and forward resources after a synchronous failure', async () => {
  let rtpCloses = 0;
  let browserCloses = 0;
  const stopped = [];
  const handler = createJanusInternalHandler({
    app: { handleCall: () => { throw new Error('voice app failed'); } },
    internalToken: 'voice-secret',
    rtpBridgeManager: {
      async createSession() {
        return {
          id: 'rtp-session',
          inboundSsrc: 123,
          streamRef: 'rtp-stream',
          mediaSessionRef: 'rtp-media',
          close() { rtpCloses += 1; }
        };
      },
      forwardStreamsForSession() {
        return [{ type: 'peer_audio', host: 'voice', port: 40000 }];
      }
    },
    browserBridgeManager: {
      createSession() {
        return {
          id: 'browser-session',
          streamRef: 'browser-stream',
          mediaSessionRef: 'browser-media',
          close() { browserCloses += 1; }
        };
      },
      streamUrlForSession() { return 'ws://voice/browser-session'; }
    },
    rtpForwardController: {
      async startForwarders() {
        return { forwarders: [{ stream_id: 1001 }] };
      },
      async stopForwarders(payload) { stopped.push(payload); }
    }
  });
  const req = fakeReq({
    body: {
      call_ref: 'sipuni:janus-ai:rollback',
      routing: { action: 'ai' },
      sip_profile: voiceAgentSipProfile(),
      janus: {
        unique_id: 'sip-handle-rollback',
        session_id: '123',
        handle_id: '456',
        rtp_bridge: { enabled: true },
        browser_bridge: { enabled: true },
        rtp_forward: { enabled: true }
      }
    }
  });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 502);
  assert.equal(rtpCloses, 1);
  assert.equal(browserCloses, 1);
  assert.deepEqual(stopped, [{
    uniqueId: 'sip-handle-rollback',
    sessionId: '123',
    handleId: '456',
    streamIds: [1001]
  }]);
});

test('Janus internal attach endpoint fails closed without a matching bearer token', async () => {
  const handler = createJanusInternalHandler({ app: { handleCall: async () => { throw new Error('must not run'); } }, internalToken: 'voice-secret' });
  const req = fakeReq({ token: 'wrong', body: { call_ref: 'sipuni:janus-ai:call-1' } });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 401);
  assert.equal(res.json().error, 'unauthorized');
});

test('Janus internal attach endpoint is disabled when the internal token is blank', async () => {
  const handler = createJanusInternalHandler({ app: { handleCall: async () => { throw new Error('must not run'); } }, internalToken: '' });
  const req = fakeReq({ token: 'voice-secret', body: { call_ref: 'sipuni:janus-ai:call-1' } });
  const res = fakeRes();

  await dispatch(handler, req, res);

  assert.equal(res.statusCode, 503);
  assert.equal(res.json().error, 'internal_token_required');
});
