const { EventEmitter } = require('node:events');
const crypto = require('node:crypto');
const WebSocket = require('ws');

const DEFAULT_PATH = '/ai-voice/janus-sip/browser-media';
const DEFAULT_INPUT_MIME_TYPE = 'audio/pcm;rate=16000';
const MAX_BUFFERED_AUDIO_OUT = 20;
const DEFAULT_MAX_PAYLOAD_BYTES = 128 << 10;
const DEFAULT_MAX_AUDIO_BYTES = 64 << 10;
const DEFAULT_MAX_SESSIONS = 256;
const DEFAULT_ATTACH_TIMEOUT_MS = 60_000;
const DEFAULT_IDLE_TIMEOUT_MS = 30_000;

class JanusBrowserBridgeManager {
  constructor({
    path = DEFAULT_PATH,
    publicBaseUrl = '',
    allowedOrigins = [],
    maxPayloadBytes = DEFAULT_MAX_PAYLOAD_BYTES,
    maxAudioBytes = DEFAULT_MAX_AUDIO_BYTES,
    maxSessions = DEFAULT_MAX_SESSIONS,
    attachTimeoutMs = DEFAULT_ATTACH_TIMEOUT_MS,
    idleTimeoutMs = DEFAULT_IDLE_TIMEOUT_MS,
    WebSocketServerImpl = WebSocket.Server
  } = {}) {
    this.path = normalizePath(path);
    this.publicBaseUrl = String(publicBaseUrl || '').replace(/\/+$/, '');
    this.allowedOrigins = new Set((allowedOrigins || []).map(normalizeOrigin).filter(Boolean));
    this.maxPayloadBytes = positiveInteger(maxPayloadBytes, DEFAULT_MAX_PAYLOAD_BYTES);
    this.maxAudioBytes = positiveInteger(maxAudioBytes, DEFAULT_MAX_AUDIO_BYTES);
    this.maxSessions = positiveInteger(maxSessions, DEFAULT_MAX_SESSIONS);
    this.attachTimeoutMs = positiveInteger(attachTimeoutMs, DEFAULT_ATTACH_TIMEOUT_MS);
    this.idleTimeoutMs = positiveInteger(idleTimeoutMs, DEFAULT_IDLE_TIMEOUT_MS);
    this.WebSocketServerImpl = WebSocketServerImpl;
    this.sessions = new Map();
    this.wss = new this.WebSocketServerImpl({
      noServer: true,
      maxPayload: this.maxPayloadBytes,
      perMessageDeflate: false
    });
  }

  createSession({ callRef = '', mediaSessionRef = '', streamRef = '' } = {}) {
    if (this.sessions.size >= this.maxSessions) {
      const error = new Error('janus browser bridge session capacity exceeded');
      error.code = 'janus_browser_bridge_capacity_exceeded';
      throw error;
    }
    const session = new JanusBrowserBridgeSession({
      manager: this,
      callRef,
      mediaSessionRef,
      streamRef
    });
    this.sessions.set(session.id, session);
    session.once('close', () => this.sessions.delete(session.id));
    return session;
  }

  getSession(id) {
    return this.sessions.get(String(id || ''));
  }

  streamUrlForSession(session) {
    if (!session) return '';
    const query = new URLSearchParams({ token: session.token });
    const path = `${this.path}/${encodeURIComponent(session.id)}?${query.toString()}`;
    return this.publicBaseUrl ? `${this.publicBaseUrl}${path}` : path;
  }

  handleUpgrade(req, socket, head) {
    const parsed = requestUrl(req);
    if (!parsed || !parsed.pathname.startsWith(`${this.path}/`)) return false;

    const sessionId = safeDecodeURIComponent(parsed.pathname.slice(this.path.length + 1));
    const session = this.getSession(sessionId);
    const origin = normalizeOrigin(req.headers?.origin);
    if (
      !session ||
      session.tokenConsumed ||
      !secureTokenMatch(parsed.searchParams.get('token'), session.token) ||
      (this.allowedOrigins.size > 0 && !this.allowedOrigins.has(origin))
    ) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return true;
    }

    session.tokenConsumed = true;
    this.wss.handleUpgrade(req, socket, head, ws => {
      this.wss.emit('connection', ws, req);
      session.attachSocket(ws);
    });
    return true;
  }
}

class JanusBrowserBridgeSession extends EventEmitter {
  constructor({ manager, callRef, mediaSessionRef, streamRef }) {
    super();
    this.manager = manager;
    this.id = `janus-browser-${crypto.randomUUID()}`;
    this.token = crypto.randomBytes(24).toString('base64url');
    this.callRef = callRef || this.id;
    this.streamRef = streamRef || this.id;
    this.mediaSessionRef = mediaSessionRef || this.id;
    this.mediaStream = new JanusBrowserBridgeMediaStream(this);
    this.ws = null;
    this.closed = false;
    this.tokenConsumed = false;
    this.pendingAudioOut = [];
    this.attachTimer = createTimer(() => this.close(), this.manager.attachTimeoutMs);
    this.idleTimer = null;
  }

  attachSocket(ws) {
    if (this.closed) {
      ws.close();
      return;
    }
    clearTimer(this.attachTimer);
    this.attachTimer = null;
    clearTimer(this.idleTimer);
    this.idleTimer = null;
    this.ws?.close?.();
    this.ws = ws;
    ws.on('message', message => this.handleMessage(message));
    ws.on('close', () => {
      if (this.ws === ws) this.ws = null;
      this.mediaStream.emit('close');
      this.scheduleIdleClose();
    });
    ws.on('error', error => this.mediaStream.emit('error', error));
    this.flushPendingAudioOut();
    this.mediaStream.emit('open');
  }

  handleMessage(message) {
    const payload = parseJson(message);
    if (!payload?.data) return;
    const data = decodeAudio(payload.data, this.manager.maxAudioBytes);
    if (!data) {
      this.ws?.close?.(1009, 'audio frame too large');
      return;
    }
    this.mediaStream.emit('payload', {
      type: payload.type || 'AUDIO_IN',
      data,
      mimeType: payload.mime_type || payload.mimeType || DEFAULT_INPUT_MIME_TYPE,
      streamRef: payload.stream_ref || payload.streamRef || this.streamRef,
      mediaSessionRef: payload.media_session_ref || payload.mediaSessionRef || this.mediaSessionRef,
      transport: 'janus_sip'
    });
  }

  sendAudioOut(payload = {}) {
    const frame = JSON.stringify({
      type: payload.type || 'AUDIO_OUT',
      data: Buffer.from(payload.data || []).toString('base64'),
      stream_ref: payload.streamRef || payload.stream_ref || this.streamRef,
      media_session_ref: payload.mediaSessionRef || payload.media_session_ref || this.mediaSessionRef,
      mime_type: payload.mimeType || payload.mime_type || 'audio/pcm;rate=8000'
    });

    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(frame);
      return true;
    }

    this.pendingAudioOut.push(frame);
    if (this.pendingAudioOut.length > MAX_BUFFERED_AUDIO_OUT) this.pendingAudioOut.shift();
    return false;
  }

  flushPendingAudioOut() {
    if (this.ws?.readyState !== WebSocket.OPEN) return;
    while (this.pendingAudioOut.length) this.ws.send(this.pendingAudioOut.shift());
  }

  scheduleIdleClose() {
    if (this.closed || this.ws) return;
    clearTimer(this.idleTimer);
    this.idleTimer = createTimer(() => this.close(), this.manager.idleTimeoutMs);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.ws?.close?.();
    this.ws = null;
    clearTimer(this.attachTimer);
    clearTimer(this.idleTimer);
    this.attachTimer = null;
    this.idleTimer = null;
    this.pendingAudioOut = [];
    this.mediaStream.emit('close');
    this.emit('close');
  }
}

class JanusBrowserBridgeMediaStream extends EventEmitter {
  constructor(session) {
    super();
    this.session = session;
    this.streamRef = session.streamRef;
    this.mediaSessionRef = session.mediaSessionRef;
    this.transport = 'janus_sip';
  }

  onPayload(handler) {
    this.on('payload', handler);
  }

  write(payload = {}) {
    return this.session.sendAudioOut(payload);
  }

  close() {
    this.session.close();
  }
}

function createJanusBrowserBridgeMediaStreamFactory({ manager } = {}) {
  return async function janusBrowserBridgeMediaStreamFactory({ request = {} } = {}) {
    const runtimeStream = request.runtime_stream || request.runtimeStream || {};
    const sessionId = runtimeStream.runtime_session_id || runtimeStream.runtimeSessionId;
    if (!manager || runtimeStream.kind !== 'browser_janus_bridge' || !sessionId) return null;
    const session = manager.getSession(sessionId);
    if (!session) throw new Error('janus browser bridge runtime session not found');
    return session.mediaStream;
  };
}

function normalizePath(path = DEFAULT_PATH) {
  const value = String(path || DEFAULT_PATH).trim() || DEFAULT_PATH;
  return value.startsWith('/') ? value.replace(/\/+$/, '') : `/${value.replace(/\/+$/, '')}`;
}

function requestUrl(req) {
  try {
    return new URL(req.url || '/', 'http://localhost');
  } catch (_error) {
    return null;
  }
}

function safeDecodeURIComponent(value) {
  try {
    return decodeURIComponent(value);
  } catch (_error) {
    return '';
  }
}

function parseJson(message) {
  try {
    const text = Buffer.isBuffer(message) ? message.toString('utf8') : String(message || '');
    return JSON.parse(text);
  } catch (_error) {
    return null;
  }
}

function decodeAudio(value, maxBytes) {
  if (typeof value !== 'string' || value.length > Math.ceil(maxBytes * 4 / 3) + 4) return null;
  const data = Buffer.from(value, 'base64');
  return data.length <= maxBytes ? data : null;
}

function positiveInteger(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function normalizeOrigin(value) {
  try {
    const url = new URL(String(value || ''));
    if (!['http:', 'https:'].includes(url.protocol)) return '';
    return url.origin.toLowerCase();
  } catch (_error) {
    return '';
  }
}

function secureTokenMatch(left, right) {
  const leftBuffer = Buffer.from(String(left || ''));
  const rightBuffer = Buffer.from(String(right || ''));
  return leftBuffer.length === rightBuffer.length && crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function createTimer(callback, timeoutMs) {
  const timer = setTimeout(callback, timeoutMs);
  timer.unref?.();
  return timer;
}

function clearTimer(timer) {
  if (timer) clearTimeout(timer);
}

module.exports = {
  DEFAULT_PATH,
  DEFAULT_MAX_PAYLOAD_BYTES,
  JanusBrowserBridgeManager,
  JanusBrowserBridgeMediaStream,
  JanusBrowserBridgeSession,
  createJanusBrowserBridgeMediaStreamFactory
};
