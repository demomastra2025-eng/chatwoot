const EventEmitter = require('node:events');
const WebSocket = require('ws');

const DEFAULT_INPUT_MIME_TYPE = 'audio/pcm;rate=16000';
const DEFAULT_OUTPUT_TYPE = 'AUDIO_OUT';
const DEFAULT_INPUT_TYPE = 'AUDIO_IN';

function createWebsocketRuntimeMediaStreamFactory({
  WebSocketImpl = WebSocket,
  transport = '',
  runtimeStreamKey = 'runtime_stream'
} = {}) {
  return async function websocketRuntimeMediaStreamFactory({ request = {} } = {}) {
    if (transport && !requestMatchesTransport(request, transport)) return null;

    const runtimeStream = runtimeStreamPayload(request, runtimeStreamKey);
    if (!runtimeStream || Object.keys(runtimeStream).length === 0) return null;

    const streamUrl = String(runtimeStream.stream_url || runtimeStream.streamUrl || '').trim();
    if (!streamUrl) throw new Error('runtime stream_url is required');
    const parsedStreamUrl = new URL(streamUrl);
    if (!['ws:', 'wss:'].includes(parsedStreamUrl.protocol)) throw new Error('runtime stream_url must use ws or wss');
    if (parsedStreamUrl.searchParams.has('token')) throw new Error('runtime stream token must not be carried in the URL');
    const streamToken = String(runtimeStream.stream_token || runtimeStream.streamToken || '').trim();
    if (!streamToken) throw new Error('runtime stream_token is required');

    const runtimeSessionId = String(runtimeStream.runtime_session_id || runtimeStream.runtimeSessionId || '').trim();
    const stream = new WebsocketRuntimeMediaStream({
      WebSocketImpl,
      url: streamUrl,
      token: streamToken,
      callRef: request.call_ref || request.callRef,
      streamRef: runtimeSessionId || request.stream_ref || request.streamRef,
      mediaSessionRef: request.media_session_ref || request.mediaSessionRef || runtimeSessionId,
      inputMimeType: runtimeStream.input_mime_type || runtimeStream.inputMimeType || DEFAULT_INPUT_MIME_TYPE,
      outputType: runtimeStream.output_type || runtimeStream.outputType || DEFAULT_OUTPUT_TYPE,
      inputType: runtimeStream.input_type || runtimeStream.inputType || DEFAULT_INPUT_TYPE,
      transport: transport || request.transport
    });

    await stream.open();
    return stream;
  };
}

class WebsocketRuntimeMediaStream extends EventEmitter {
  constructor({ WebSocketImpl, url, token, callRef, streamRef, mediaSessionRef, inputMimeType, outputType, inputType, transport }) {
    super();
    this.WebSocketImpl = WebSocketImpl;
    this.url = url;
    this.token = token;
    this.callRef = callRef;
    this.streamRef = streamRef || callRef;
    this.mediaSessionRef = mediaSessionRef || this.streamRef;
    this.inputMimeType = inputMimeType || DEFAULT_INPUT_MIME_TYPE;
    this.outputType = outputType || DEFAULT_OUTPUT_TYPE;
    this.inputType = inputType || DEFAULT_INPUT_TYPE;
    this.transport = transport;
    this.ws = null;
  }

  open() {
    this.ws = new this.WebSocketImpl(this.url, {
      headers: { authorization: 'Bearer ' + this.token }
    });
    wireWebSocket(this.ws, {
      onOpen: () => this.emit('open'),
      onMessage: message => this.handleMessage(message),
      onClose: () => this.emit('close'),
      onError: error => this.emit('error', error)
    });

    return new Promise((resolve, reject) => {
      const cleanup = () => {
        this.off('open', handleOpen);
        this.off('error', handleError);
        this.off('close', handleClose);
      };
      const handleOpen = () => {
        cleanup();
        resolve(this);
      };
      const handleError = error => {
        cleanup();
        reject(error);
      };
      const handleClose = () => {
        cleanup();
        reject(new Error('runtime stream closed before open'));
      };
      this.once('open', handleOpen);
      this.once('error', handleError);
      this.once('close', handleClose);
    });
  }

  onPayload(handler) {
    this.on('payload', handler);
  }

  write(payload = {}) {
    if (!this.ws || typeof this.ws.send !== 'function') throw new Error('runtime stream is not open');
    const frame = {
      type: payload.type || this.outputType,
      data: Buffer.from(payload.data || []).toString('base64')
    };
    this.ws.send(JSON.stringify(frame));
  }

  close() {
    this.ws?.close?.();
  }

  handleMessage(message) {
    const parsed = parseRuntimeMessage(message);
    if (!parsed?.data) return;

    this.emit('payload', {
      type: parsed.type || this.inputType,
      data: Buffer.from(parsed.data, 'base64'),
      mimeType: parsed.mime_type || parsed.mimeType || this.inputMimeType,
      streamRef: parsed.stream_ref || parsed.streamRef || this.streamRef,
      mediaSessionRef: parsed.media_session_ref || parsed.mediaSessionRef || this.mediaSessionRef,
      transport: this.transport
    });
  }
}

function runtimeStreamPayload(request = {}, runtimeStreamKey = 'runtime_stream') {
  return request[runtimeStreamKey] || request.runtime_stream || request.runtimeStream || {};
}

function requestMatchesTransport(request = {}, expectedTransport = '') {
  const expected = normalizeTransport(expectedTransport);
  const actual = normalizeTransport(request.transport || request.runtime_transport || request.runtimeTransport);
  if (!actual) return false;
  return actual === expected;
}

function normalizeTransport(value = '') {
  return String(value || '').trim().toLowerCase().replace(/[-\s]+/g, '_');
}

function parseRuntimeMessage(message) {
  const text = Buffer.isBuffer(message) ? message.toString('utf8') : String(message || '');
  if (!text.trim()) return null;

  try {
    return JSON.parse(text);
  } catch (_error) {
    return null;
  }
}

function wireWebSocket(ws, { onOpen, onMessage, onClose, onError }) {
  if (typeof ws.once === 'function') ws.once('open', onOpen);
  else if (typeof ws.on === 'function') ws.on('open', onOpen);

  if (typeof ws.on === 'function') {
    ws.on('message', onMessage);
    ws.on('close', onClose);
    ws.on('error', onError);
  }
}

module.exports = {
  DEFAULT_INPUT_MIME_TYPE,
  DEFAULT_OUTPUT_TYPE,
  DEFAULT_INPUT_TYPE,
  WebsocketRuntimeMediaStream,
  createWebsocketRuntimeMediaStreamFactory,
  parseRuntimeMessage
};
