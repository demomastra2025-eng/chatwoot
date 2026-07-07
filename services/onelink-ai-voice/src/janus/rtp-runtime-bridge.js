const { EventEmitter } = require('node:events');
const dgram = require('node:dgram');
const crypto = require('node:crypto');
const {
  buildRtpPacket,
  decodeTelephonyPayload,
  downsamplePcm16By2,
  encodeTelephonyPayload,
  normalizeCodec,
  parseRtpPacket,
  payloadTypeForCodec,
  upsamplePcm16By2
} = require('./rtp-packet');

const DEFAULT_INPUT_SAMPLE_RATE = 8000;
const DEFAULT_RUNTIME_SAMPLE_RATE = 16000;

class JanusRtpRuntimeBridgeManager extends EventEmitter {
  constructor({
    enabled = false,
    listenHost = '0.0.0.0',
    listenPort = 0,
    publicHost = '',
    inputCodec = 'pcmu',
    outputCodec = '',
    outputHost = '',
    outputPort = 0,
    outputPayloadType = null,
    dgramImpl = dgram
  } = {}) {
    super();
    this.enabled = Boolean(enabled);
    this.listenHost = listenHost || '0.0.0.0';
    this.listenPort = Number(listenPort) || 0;
    this.boundPort = 0;
    this.publicHost = publicHost || '';
    this.inputCodec = normalizeCodec(inputCodec);
    this.outputCodec = normalizeCodec(outputCodec || inputCodec);
    this.outputHost = outputHost || '';
    this.outputPort = Number(outputPort) || 0;
    this.outputPayloadType = positiveInteger(outputPayloadType) || payloadTypeForCodec(this.outputCodec);
    this.dgramImpl = dgramImpl;
    this.socket = null;
    this.startPromise = null;
    this.sessions = new Map();
    this.sessionsBySsrc = new Map();
  }

  async start() {
    if (!this.enabled) throw new Error('janus RTP runtime bridge is disabled');
    if (this.socket) return this;
    if (this.startPromise) return this.startPromise;

    this.startPromise = new Promise((resolve, reject) => {
      const socket = this.dgramImpl.createSocket('udp4');
      const fail = error => {
        cleanup();
        this.startPromise = null;
        reject(error);
      };
      const ready = () => {
        cleanup();
        this.socket = socket;
        this.boundPort = socket.address().port;
        socket.on('message', (message, remote) => this.handleRtpMessage(message, remote));
        socket.on('error', error => this.emit('error', error));
        resolve(this);
      };
      const cleanup = () => {
        socket.off?.('error', fail);
        socket.off?.('listening', ready);
      };
      socket.once('error', fail);
      socket.once('listening', ready);
      socket.bind(this.listenPort, this.listenHost);
    });

    return this.startPromise;
  }

  async createSession({
    callRef,
    mediaSessionRef = '',
    streamRef = '',
    inboundSsrc = null,
    inputCodec = '',
    output = {}
  } = {}) {
    await this.start();
    const session = new JanusRtpRuntimeBridgeSession({
      manager: this,
      callRef,
      mediaSessionRef,
      streamRef,
      inboundSsrc: positiveInteger(inboundSsrc) || randomSsrc(),
      inputCodec: inputCodec || this.inputCodec,
      outputCodec: output.codec || this.outputCodec,
      outputHost: output.host || this.outputHost,
      outputPort: output.port || this.outputPort,
      outputPayloadType: positiveInteger(output.payload_type || output.payloadType) || this.outputPayloadType,
      outputSsrc: positiveInteger(output.ssrc) || randomSsrc()
    });

    this.sessions.set(session.id, session);
    this.sessionsBySsrc.set(session.inboundSsrc, session);
    session.once('close', () => {
      this.sessions.delete(session.id);
      this.sessionsBySsrc.delete(session.inboundSsrc);
    });
    return session;
  }

  getSession(id) {
    return this.sessions.get(String(id || ''));
  }

  forwardStreamsForSession(session, overrides = {}) {
    if (!session) return [];
    const host = overrides.host || this.publicHost;
    if (!host) throw new Error('janus RTP bridge public host is required');
    return [{
      type: overrides.type || 'peer_audio',
      host,
      host_family: overrides.host_family || overrides.hostFamily || 'ipv4',
      port: positiveInteger(overrides.port) || this.boundPort || this.listenPort,
      ssrc: session.inboundSsrc,
      pt: positiveInteger(overrides.pt || overrides.payload_type || overrides.payloadType)
    }].map(compact);
  }

  handleRtpMessage(message, remote) {
    const packet = parseRtpPacket(message);
    if (!packet) return;
    const session = this.sessionsBySsrc.get(packet.ssrc) || singleActiveSession(this.sessions);
    if (!session) return;
    session.handleInboundRtp(packet, remote);
  }

  sendRtp(session, packet) {
    if (!this.socket || !session.outputHost || !session.outputPort) return false;
    this.socket.send(packet, session.outputPort, session.outputHost);
    return true;
  }

  close() {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
    this.sessionsBySsrc.clear();
    this.socket?.close?.();
    this.socket = null;
    this.startPromise = null;
  }
}

class JanusRtpRuntimeBridgeSession extends EventEmitter {
  constructor({
    manager,
    callRef,
    mediaSessionRef,
    streamRef,
    inboundSsrc,
    inputCodec,
    outputCodec,
    outputHost,
    outputPort,
    outputPayloadType,
    outputSsrc
  }) {
    super();
    this.manager = manager;
    this.id = `janus-rtp-${crypto.randomUUID()}`;
    this.callRef = callRef || this.id;
    this.mediaSessionRef = mediaSessionRef || this.id;
    this.streamRef = streamRef || this.id;
    this.inboundSsrc = inboundSsrc;
    this.inputCodec = normalizeCodec(inputCodec);
    this.outputCodec = normalizeCodec(outputCodec);
    this.outputHost = outputHost || '';
    this.outputPort = Number(outputPort) || 0;
    this.outputPayloadType = positiveInteger(outputPayloadType) || payloadTypeForCodec(this.outputCodec);
    this.outputSsrc = outputSsrc;
    this.sequenceNumber = 0;
    this.timestamp = 0;
    this.closed = false;
    this.mediaStream = new JanusRtpBridgeMediaStream(this);
  }

  handleInboundRtp(packet, remote) {
    if (this.closed) return;
    const pcm8 = decodeTelephonyPayload(packet.payload, this.inputCodec);
    const pcm16 = upsamplePcm16By2(pcm8);
    this.emit('rtp_in', { packet, remote, bytes: packet.payload.length });
    this.mediaStream.emit('payload', {
      type: 'AUDIO_IN',
      data: pcm16,
      mimeType: `audio/pcm;rate=${DEFAULT_RUNTIME_SAMPLE_RATE}`,
      streamRef: this.streamRef,
      mediaSessionRef: this.mediaSessionRef,
      transport: 'janus_sip'
    });
  }

  writePcm16(pcm16) {
    if (this.closed) return false;
    const pcm8 = downsamplePcm16By2(pcm16);
    const payload = encodeTelephonyPayload(pcm8, this.outputCodec);
    const packet = buildRtpPacket({
      payload,
      payloadType: this.outputPayloadType,
      sequenceNumber: this.sequenceNumber,
      timestamp: this.timestamp,
      ssrc: this.outputSsrc
    });
    this.sequenceNumber = (this.sequenceNumber + 1) & 0xffff;
    this.timestamp = (this.timestamp + Math.max(1, pcm8.length / 2)) >>> 0;
    const sent = this.manager.sendRtp(this, packet);
    this.emit('rtp_out', { bytes: payload.length, sent });
    return sent;
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.mediaStream.emit('close');
    this.emit('close');
  }
}

class JanusRtpBridgeMediaStream extends EventEmitter {
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
    const data = Buffer.isBuffer(payload.data) ? payload.data : Buffer.from(payload.data || []);
    if (!data.length) return false;
    return this.session.writePcm16(data);
  }

  close() {
    this.session.close();
  }
}

function createJanusRtpBridgeMediaStreamFactory({ manager } = {}) {
  return async function janusRtpBridgeMediaStreamFactory({ request = {} } = {}) {
    const runtimeStream = request.runtime_stream || request.runtimeStream || {};
    const sessionId = runtimeStream.runtime_session_id || runtimeStream.runtimeSessionId;
    if (!manager || runtimeStream.kind !== 'janus_rtp_bridge' || !sessionId) return null;
    const session = manager.getSession(sessionId);
    if (!session) throw new Error('janus RTP bridge runtime session not found');
    return session.mediaStream;
  };
}

function singleActiveSession(sessions) {
  return sessions.size === 1 ? sessions.values().next().value : null;
}

function randomSsrc() {
  return crypto.randomBytes(4).readUInt32BE(0) || 1;
}

function positiveInteger(value) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function compact(object) {
  return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = {
  DEFAULT_INPUT_SAMPLE_RATE,
  DEFAULT_RUNTIME_SAMPLE_RATE,
  JanusRtpBridgeMediaStream,
  JanusRtpRuntimeBridgeManager,
  JanusRtpRuntimeBridgeSession,
  createJanusRtpBridgeMediaStreamFactory
};
