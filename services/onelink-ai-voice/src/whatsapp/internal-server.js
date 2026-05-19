const { EventEmitter } = require('node:events');

const DEFAULT_ATTACH_PATH = '/internal/whatsapp-cloud/calls';
const MAX_BODY_BYTES = 1024 * 1024;

function createWhatsappInternalHandler({ app, internalToken = '', path = DEFAULT_ATTACH_PATH } = {}) {
  const attachPath = normalizePath(path);
  return function whatsappInternalHandler(req, res) {
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
      .then(payload => handleAttach({ app, payload, res }))
      .catch(error => writeJson(res, error.statusCode || 400, { error: error.code || 'invalid_json' }));
    return true;
  };
}

async function handleAttach({ app, payload, res }) {
  const request = normalizeAttachPayload(payload || {});
  if (!request.call_ref && !request.callRef) {
    writeJson(res, 422, { error: 'call_ref_required' });
    return;
  }

  try {
    const result = await app.handleCall(buildWhatsappCallFacade(request), request);
    writeJson(res, 202, {
      status: 'accepted',
      mode: result?.mode || 'accepted',
      call_ref: request.call_ref || request.callRef
    });
  } catch (error) {
    writeJson(res, 502, { error: 'attach_failed', message: sanitizeMessage(error?.message) });
  }
}

function buildWhatsappCallFacade(request) {
  const call = new EventEmitter();
  call.request = request;
  call.answer = async () => true;
  call.hangup = async () => {
    call.emit('end');
    return true;
  };
  call.reject = async () => call.hangup();
  call.stream = async () => {
    throw new Error('whatsapp runtime stream factory is not configured');
  };
  return call;
}

function normalizeAttachPayload(payload) {
  const runtimeStream = payload.runtime_stream || payload.runtimeStream || {};
  const normalized = {
    ...payload,
    call_ref: payload.call_ref || payload.callRef,
    account_id: payload.account_id || payload.accountId,
    inbox_id: payload.inbox_id || payload.inboxId,
    conversation_id: payload.conversation_id || payload.conversationId,
    whatsapp_call_id: payload.whatsapp_call_id || payload.whatsappCallId,
    call_session_id: payload.call_session_id || payload.callSessionId,
    media_session_ref: payload.media_session_ref || payload.mediaSessionRef || payload.media_session_id || payload.mediaSessionId,
    media_session_id: payload.media_session_id || payload.mediaSessionId,
    stream_ref: payload.stream_ref || payload.streamRef || runtimeStream.runtime_session_id || runtimeStream.runtimeSessionId,
    runtime_stream: runtimeStream,
    routing: payload.routing || payload.route_decision || payload.routeDecision || { action: 'ai', reason: 'whatsapp_cloud_ai_voice_attach' }
  };
  return normalized;
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
  createWhatsappInternalHandler,
  buildWhatsappCallFacade,
  normalizeAttachPayload
};
