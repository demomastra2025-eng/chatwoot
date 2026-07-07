const { EventEmitter } = require('node:events');
const crypto = require('node:crypto');
const WebSocket = require('ws');

const DEFAULT_PATH = '/ai-voice/janus-sip/browser-media';
const DEFAULT_INPUT_MIME_TYPE = 'audio/pcm;rate=16000';
const MAX_BUFFERED_AUDIO_OUT = 20;

class JanusBrowserBridgeManager {
  constructor({ path = DEFAULT_PATH, publicBaseUrl = '', WebSocketServerImpl = WebSocket.Server } = {}) {
    this.path = normalizePath(path);
    this.publicBaseUrl = String(publicBaseUrl || '').replace(/\/+$/, '');
    this.WebSocketServerImpl = WebSocketServerImpl;
    this.sessions = new Map();
    this.wss = new this.WebSocketServerImpl({ noServer: true });
  }

  createSession({ callRef = '', mediaSessionRef = '', streamRef = '' } = {}) {
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

    const sessionId = decodeURIComponent(parsed.pathname.slice(this.path.length + 1));
    const session = this.getSession(sessionId);
    if (!session || parsed.searchParams.get('token') !== session.token) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return true;
    }

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
    this.pendingAudioOut = [];
  }

  attachSocket(ws) {
    if (this.closed) {
      ws.close();
      return;
    }
    this.ws?.close?.();
    this.ws = ws;
    ws.on('message', message => this.handleMessage(message));
    ws.on('close', () => {
      if (this.ws === ws) this.ws = null;
      this.mediaStream.emit('close');
    });
    ws.on('error', error => this.mediaStream.emit('error', error));
    this.flushPendingAudioOut();
    this.mediaStream.emit('open');
  }

  handleMessage(message) {
    const payload = parseJson(message);
    if (!payload?.data) return;
    this.mediaStream.emit('payload', {
      type: payload.type || 'AUDIO_IN',
      data: Buffer.from(payload.data, 'base64'),
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

  close() {
    if (this.closed) return;
    this.closed = true;
    this.ws?.close?.();
    this.ws = null;
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

function parseJson(message) {
  try {
    const text = Buffer.isBuffer(message) ? message.toString('utf8') : String(message || '');
    return JSON.parse(text);
  } catch (_error) {
    return null;
  }
}

module.exports = {
  DEFAULT_PATH,
  JanusBrowserBridgeManager,
  JanusBrowserBridgeMediaStream,
  JanusBrowserBridgeSession,
  createJanusBrowserBridgeMediaStreamFactory
};
