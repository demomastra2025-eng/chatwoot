const { EventEmitter } = require('node:events');
const { assertAiRoute } = require('../runtime/selector');

const DEFAULT_ATTACH_PATH = '/internal/janus-sip/calls';
const MAX_BODY_BYTES = 1024 * 1024;

function createJanusInternalHandler({
  app,
  internalToken = '',
  path = DEFAULT_ATTACH_PATH,
  rtpForwardController = null,
  rtpBridgeManager = null,
  browserBridgeManager = null,
  allowedProviders = [],
  runtimeSelector = null
} = {}) {
  const attachPath = normalizePath(path);
  return function janusInternalHandler(req, res) {
    const pathname = requestPath(req);
    if (req.method !== 'POST' || pathname !== attachPath) return false;

    res.setHeader('content-type', 'application/json');
    if (!String(internalToken || '').trim()) {
      writeJson(res, 503, { error: 'internal_token_required' });
      return true;
    }
    if (authorizationToken(req) !== internalToken) {
      writeJson(res, 401, { error: 'unauthorized' });
      return true;
    }
    if (!app || typeof app.handleCall !== 'function') {
      writeJson(res, 503, { error: 'voice_app_unavailable' });
      return true;
    }

    readJsonBody(req)
      .then(payload => handleAttach({
        app,
        payload,
        res,
        rtpForwardController,
        rtpBridgeManager,
        browserBridgeManager,
        allowedProviders,
        runtimeSelector
      }))
      .catch(error => writeJson(res, error.statusCode || 400, { error: error.code || 'invalid_json' }));
    return true;
  };
}

async function handleAttach({
  app,
  payload,
  res,
  rtpForwardController = null,
  rtpBridgeManager = null,
  browserBridgeManager = null,
  allowedProviders = [],
  runtimeSelector = null
}) {
  const request = normalizeAttachPayload(payload || {});
  if (!request.call_ref && !request.callRef) {
    writeJson(res, 422, { error: 'call_ref_required' });
    return;
  }
  if (!providerAllowed(request.provider, allowedProviders)) {
    writeJson(res, 422, {
      error: 'provider_not_allowed',
      provider: request.provider,
      allowed_providers: normalizedAllowedProviders(allowedProviders)
    });
    return;
  }
  if (!request.sip_profile || request.sip_profile.voice_agent !== true) {
    writeJson(res, 422, { error: 'voice_agent_sip_profile_required' });
    return;
  }

  const callRef = request.call_ref || request.callRef;
  const resources = {
    rtpBridgeSession: null,
    browserBridgeSession: null,
    rtpForwardResult: null
  };
  try {
    assertAiRoute(request);
    const runtimeEngine = runtimeSelector?.select?.(request) || 'legacy';
    if (runtimeEngine === 'pipecat') {
      const error = new Error('Pipecat requires the server-side Janus media runtime');
      error.code = 'pipecat_internal_janus_unsupported';
      error.statusCode = 503;
      throw error;
    }
    resources.rtpBridgeSession = await prepareRequestedRtpBridge({ request, rtpBridgeManager });
    resources.browserBridgeSession = await prepareRequestedBrowserBridge({ request, browserBridgeManager });
    resources.rtpForwardResult = await startRequestedRtpForward({ request, rtpForwardController });
    const run = app.handleCall(buildJanusCallFacade(request), request);
    observeVoiceAppRun(run, callRef);
    writeJson(res, 202, {
      status: 'accepted',
      mode: 'accepted',
      call_ref: callRef,
      transport: request.transport,
      browser_bridge: request.janus?.browser_bridge_result
    });
  } catch (error) {
    await rollbackRequestedJanusResources({
      request,
      resources,
      rtpForwardController,
      callRef
    });
    writeJson(res, error.statusCode || 502, {
      error: error.code || 'attach_failed',
      message: sanitizeMessage(error?.message)
    });
  }
}

async function rollbackRequestedJanusResources({
  request,
  resources,
  rtpForwardController,
  callRef
}) {
  const streamIds = forwarderStreamIds(resources.rtpForwardResult);
  if (streamIds.length > 0 && typeof rtpForwardController?.stopForwarders === 'function') {
    try {
      await rtpForwardController.stopForwarders({
        uniqueId: request.janus?.unique_id,
        sessionId: request.janus?.session_id,
        handleId: request.janus?.handle_id,
        streamIds
      });
    } catch (error) {
      logAttachError('rollback_rtp_forward', callRef, error);
    }
  }
  for (const [scope, session] of [
    ['rollback_browser_bridge', resources.browserBridgeSession],
    ['rollback_rtp_bridge', resources.rtpBridgeSession]
  ]) {
    try {
      session?.close?.();
    } catch (error) {
      logAttachError(scope, callRef, error);
    }
  }
}

function forwarderStreamIds(result) {
  const forwarders = result?.forwarders || result?.streams || [];
  if (!Array.isArray(forwarders)) return [];
  return forwarders
    .map(forwarder => Number(forwarder?.stream_id || forwarder?.streamId || forwarder?.id))
    .filter(value => Number.isInteger(value) && value > 0);
}

async function prepareRequestedBrowserBridge({ request, browserBridgeManager, required = false }) {
  const browserBridge = request.janus?.browser_bridge || request.browser_bridge;
  if (!required && (!browserBridge || browserBridge.enabled !== true)) return null;
  if (!browserBridgeManager || typeof browserBridgeManager.createSession !== 'function') {
    const error = new Error('janus browser bridge manager is not configured');
    error.code = 'janus_browser_bridge_unavailable';
    throw error;
  }

  const session = browserBridgeManager.createSession({
    callRef: request.call_ref || request.callRef,
    mediaSessionRef: request.media_session_ref || request.mediaSessionRef,
    streamRef: request.stream_ref || request.streamRef
  });
  try {
    request.stream_ref = request.stream_ref || session.streamRef;
    request.media_session_ref = request.media_session_ref || session.mediaSessionRef;
    request.runtime_stream = {
      ...(request.runtime_stream || {}),
      kind: 'browser_janus_bridge',
      runtime_session_id: session.id,
      ...(required ? {
        stream_url: browserBridgeManager.streamUrlForSession(session, { includeToken: false }),
        stream_token: session.token,
        codec: 'pcm_s16le',
        input_sample_rate: 16000,
        output_sample_rate: 8000
      } : {}),
      input_mime_type: 'audio/pcm;rate=16000',
      output_mime_type: 'audio/pcm;rate=8000'
    };
    if (!required) {
      request.janus.browser_bridge_result = {
        runtime_session_id: session.id,
        stream_ref: session.streamRef,
        media_session_ref: session.mediaSessionRef,
        stream_url: browserBridgeManager.streamUrlForSession(session)
      };
    }
    return session;
  } catch (error) {
    session?.close?.();
    throw error;
  }
}

async function prepareRequestedRtpBridge({ request, rtpBridgeManager }) {
  const rtpBridge = request.janus?.rtp_bridge || request.rtp_bridge;
  if (!rtpBridge || rtpBridge.enabled !== true) return null;
  if (!rtpBridgeManager || typeof rtpBridgeManager.createSession !== 'function') {
    const error = new Error('janus RTP bridge manager is not configured');
    error.code = 'janus_rtp_bridge_unavailable';
    throw error;
  }

  const session = await rtpBridgeManager.createSession({
    callRef: request.call_ref || request.callRef,
    mediaSessionRef: request.media_session_ref || request.mediaSessionRef,
    streamRef: request.stream_ref || request.streamRef,
    inboundSsrc: rtpBridge.inbound_ssrc || rtpBridge.inboundSsrc || request.janus?.rtp_forward?.ssrc,
    inputCodec: rtpBridge.input_codec || rtpBridge.inputCodec,
    output: rtpBridge.output || {}
  });

  try {
    request.stream_ref = request.stream_ref || session.streamRef;
    request.media_session_ref = request.media_session_ref || session.mediaSessionRef;
    request.runtime_stream = {
      ...(request.runtime_stream || {}),
      kind: 'janus_rtp_bridge',
      runtime_session_id: session.id,
      input_mime_type: 'audio/pcm;rate=16000',
      output_mime_type: 'audio/pcm;rate=8000'
    };
    request.janus.rtp_bridge_result = {
      runtime_session_id: session.id,
      inbound_ssrc: session.inboundSsrc,
      stream_ref: session.streamRef,
      media_session_ref: session.mediaSessionRef
    };

    const rtpForward = request.janus.rtp_forward || {};
    if (rtpForward.enabled === true && (!Array.isArray(rtpForward.streams) || rtpForward.streams.length === 0)) {
      request.janus.rtp_forward = {
        ...rtpForward,
        streams: rtpBridgeManager.forwardStreamsForSession(session, rtpForward.stream || {})
      };
    }
    return session;
  } catch (error) {
    session?.close?.();
    throw error;
  }
}

async function startRequestedRtpForward({ request, rtpForwardController }) {
  const rtpForward = request.janus?.rtp_forward || request.rtp_forward;
  if (!rtpForward || rtpForward.enabled !== true) return null;
  if (!rtpForwardController || typeof rtpForwardController.startForwarders !== 'function') {
    const error = new Error('janus RTP forward controller is not configured');
    error.code = 'janus_rtp_forward_unavailable';
    throw error;
  }

  const response = await rtpForwardController.startForwarders({
    uniqueId: request.janus?.unique_id,
    sessionId: request.janus?.session_id,
    handleId: request.janus?.handle_id,
    streams: Array.isArray(rtpForward.streams) ? rtpForward.streams : null
  });
  request.janus.rtp_forward_result = response;
  return response;
}

function observeVoiceAppRun(run, callRef) {
  Promise.resolve(run)
    .then(result => {
      const completion = result?.completion;
      if (completion && typeof completion.then === 'function') {
        completion.catch(error => logAttachError('completion', callRef, error));
      }
    })
    .catch(error => logAttachError('handle_call', callRef, error));
}

function logAttachError(scope, callRef, error) {
  const payload = {
    event: 'janus_internal_attach_error',
    scope,
    call_ref: String(callRef || '').slice(0, 120),
    message: sanitizeMessage(error?.message || error)
  };
  console.error(JSON.stringify(payload));
}

function buildJanusCallFacade(request) {
  const call = new EventEmitter();
  call.request = request;
  call.answer = async () => true;
  call.hangup = async () => {
    call.emit('end');
    return true;
  };
  call.reject = async () => call.hangup();
  call.stream = async () => {
    throw new Error('janus runtime stream factory is not configured');
  };
  return call;
}

function normalizeAttachPayload(payload) {
  const runtimeStream = payload.runtime_stream || payload.runtimeStream || {};
  const janus = payload.janus || {};
  const normalized = {
    ...payload,
    call_ref: payload.call_ref || payload.callRef,
    bridge_call_ref: payload.bridge_call_ref || payload.bridgeCallRef || payload.janus_call_ref || payload.janusCallRef,
    account_id: payload.account_id || payload.accountId,
    inbox_id: payload.inbox_id || payload.inboxId,
    conversation_id: payload.conversation_id || payload.conversationId,
    call_session_id: payload.call_session_id || payload.callSessionId,
    number_ref: payload.number_ref || payload.numberRef,
    provider: payload.provider || 'janus_sip',
    direction: payload.direction || 'inbound',
    transport: payload.transport || payload.runtime_transport || payload.runtimeTransport || 'janus_sip',
    media_session_ref: payload.media_session_ref || payload.mediaSessionRef || janus.media_session_ref || janus.mediaSessionRef,
    media_session_id: payload.media_session_id || payload.mediaSessionId || janus.media_session_id || janus.mediaSessionId,
    stream_ref: payload.stream_ref || payload.streamRef || runtimeStream.runtime_session_id || runtimeStream.runtimeSessionId,
    runtime_stream: runtimeStream,
    janus: {
      ...janus,
      unique_id: payload.janus_unique_id || payload.janusUniqueId || janus.unique_id || janus.uniqueId,
      session_id: payload.janus_session_id || payload.janusSessionId || janus.session_id || janus.sessionId,
      handle_id: payload.janus_handle_id || payload.janusHandleId || janus.handle_id || janus.handleId,
      plugin: payload.janus_plugin || payload.janusPlugin || janus.plugin || 'janus.plugin.sip',
      rtp_forward: payload.rtp_forward || payload.rtpForward || janus.rtp_forward || janus.rtpForward,
      rtp_bridge: payload.rtp_bridge || payload.rtpBridge || janus.rtp_bridge || janus.rtpBridge,
      browser_bridge: payload.browser_bridge || payload.browserBridge || janus.browser_bridge || janus.browserBridge
    },
    routing: payload.routing || payload.route_decision || payload.routeDecision
  };
  return normalized;
}

function providerAllowed(provider, allowedProviders = []) {
  const allowed = normalizedAllowedProviders(allowedProviders);
  if (allowed.length === 0) return true;
  return allowed.includes(String(provider || '').trim().toLowerCase());
}

function normalizedAllowedProviders(allowedProviders = []) {
  if (Array.isArray(allowedProviders)) {
    return allowedProviders.map(provider => String(provider || '').trim().toLowerCase()).filter(Boolean);
  }
  return String(allowedProviders || '').split(',').map(provider => provider.trim().toLowerCase()).filter(Boolean);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        const error = new Error('request_body_too_large');
        error.statusCode = 413;
        error.code = 'request_body_too_large';
        reject(error);
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        const text = Buffer.concat(chunks).toString('utf8');
        resolve(text.trim() ? JSON.parse(text) : {});
      } catch (_error) {
        const error = new Error('invalid_json');
        error.statusCode = 400;
        error.code = 'invalid_json';
        reject(error);
      }
    });
    req.on('error', reject);
  });
}

function authorizationToken(req) {
  const header = req.headers?.authorization || req.headers?.Authorization || '';
  const match = String(header).match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : '';
}

function requestPath(req) {
  try {
    return new URL(req.url || '/', 'http://localhost').pathname;
  } catch (_error) {
    return '/';
  }
}

function normalizePath(path) {
  const value = String(path || DEFAULT_ATTACH_PATH).trim() || DEFAULT_ATTACH_PATH;
  return value.startsWith('/') ? value : `/${value}`;
}

function sanitizeMessage(message = '') {
  return String(message || '').slice(0, 200);
}

function writeJson(res, statusCode, body) {
  res.statusCode = statusCode;
  res.end(JSON.stringify(body));
}

module.exports = {
  DEFAULT_ATTACH_PATH,
  buildJanusCallFacade,
  createJanusInternalHandler,
  normalizeAttachPayload,
  providerAllowed
};
