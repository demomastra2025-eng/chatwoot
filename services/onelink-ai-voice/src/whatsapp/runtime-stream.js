const EventEmitter = require('node:events');
const WebSocket = require('ws');

const DEFAULT_INPUT_MIME_TYPE = 'audio/pcm;rate=16000';
const DEFAULT_OUTPUT_TYPE = 'AUDIO_OUT';
const DEFAULT_INPUT_TYPE = 'AUDIO_IN';

function createWhatsappRuntimeMediaStreamFactory({ WebSocketImpl = WebSocket } = {}) {
  return async function whatsappRuntimeMediaStreamFactory({ request = {} } = {}) {
    const runtimeStream = request.runtime_stream || request.runtimeStream || {};
    const streamUrl = String(runtimeStream.stream_url || runtimeStream.streamUrl || '').trim();
    if (!streamUrl) throw new Error('runtime stream_url is required');

    const runtimeSessionId = String(runtimeStream.runtime_session_id || runtimeStream.runtimeSessionId || '').trim();
    const stream = new WhatsappRuntimeMediaStream({
      WebSocketImpl,
      url: streamUrl,
      callRef: request.call_ref || request.callRef,
      streamRef: runtimeSessionId,
      inputMimeType: runtimeStream.input_mime_type || runtimeStream.inputMimeType || DEFAULT_INPUT_MIME_TYPE
    });

    await stream.open();
    return stream;
  };
}

class WhatsappRuntimeMediaStream extends EventEmitter {
  constructor({ WebSocketImpl, url, callRef, streamRef, inputMimeType }) {
    super();
    this.WebSocketImpl = WebSocketImpl;
    this.url = url;
    this.callRef = callRef;
    this.streamRef = streamRef || callRef;
    this.mediaSessionRef = this.streamRef;
    this.inputMimeType = inputMimeType || DEFAULT_INPUT_MIME_TYPE;
    this.ws = null;
  }

  open() {
    this.ws = new this.WebSocketImpl(this.url);
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
      type: payload.type || DEFAULT_OUTPUT_TYPE,
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
      type: parsed.type || DEFAULT_INPUT_TYPE,
      data: Buffer.from(parsed.data, 'base64'),
      mimeType: parsed.mime_type || parsed.mimeType || this.inputMimeType,
      streamRef: this.streamRef,
      mediaSessionRef: this.mediaSessionRef
    });
  }
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
  createWhatsappRuntimeMediaStreamFactory,
  WhatsappRuntimeMediaStream
};
