const VALID_STREAM_TYPES = new Set(['audio', 'video', 'peer_audio', 'peer_video']);

class JanusSipRtpForwardController {
  constructor({
    client,
    adminKey = '',
    defaultHost = '',
    defaultHostFamily = 'ipv4',
    defaultPeerAudioPort = 0,
    defaultAudioPort = 0,
    defaultPayloadType = null
  } = {}) {
    this.client = client;
    this.adminKey = adminKey;
    this.defaultHost = defaultHost;
    this.defaultHostFamily = defaultHostFamily || 'ipv4';
    this.defaultPeerAudioPort = Number(defaultPeerAudioPort) || 0;
    this.defaultAudioPort = Number(defaultAudioPort) || 0;
    this.defaultPayloadType = Number(defaultPayloadType) || null;
  }

  async startForwarders({ uniqueId, streams = null, sessionId = null, handleId = null } = {}) {
    const request = buildRtpForwardRequest({
      uniqueId,
      adminKey: this.adminKey,
      streams: streams || this.defaultStreams()
    });
    return this.client.messagePlugin({ request, sessionId, handleId });
  }

  async stopForwarders({ uniqueId, streamIds, sessionId = null, handleId = null } = {}) {
    const request = buildStopRtpForwardRequest({ uniqueId, streamIds, adminKey: this.adminKey });
    return this.client.messagePlugin({ request, sessionId, handleId });
  }

  async listForwarders({ uniqueId, sessionId = null, handleId = null } = {}) {
    const request = buildListForwardersRequest({ uniqueId, adminKey: this.adminKey });
    return this.client.messagePlugin({ request, sessionId, handleId });
  }

  defaultStreams() {
    const streams = [];
    if (this.defaultPeerAudioPort) {
      streams.push({
        type: 'peer_audio',
        host: this.defaultHost,
        host_family: this.defaultHostFamily,
        port: this.defaultPeerAudioPort,
        pt: this.defaultPayloadType
      });
    }
    if (this.defaultAudioPort) {
      streams.push({
        type: 'audio',
        host: this.defaultHost,
        host_family: this.defaultHostFamily,
        port: this.defaultAudioPort,
        pt: this.defaultPayloadType
      });
    }
    return streams;
  }
}

function buildRtpForwardRequest({ uniqueId, streams = [], adminKey = '' } = {}) {
  const normalizedStreams = streams.map(normalizeRtpStream);
  if (!String(uniqueId || '').trim()) throw new Error('janus unique_id is required for Admin API rtp_forward');
  if (normalizedStreams.length === 0) throw new Error('at least one RTP forward stream is required');

  return compactObject({
    request: 'rtp_forward',
    unique_id: String(uniqueId),
    admin_key: adminKey || undefined,
    streams: normalizedStreams
  });
}

function buildStopRtpForwardRequest({ uniqueId, streamIds = [], adminKey = '' } = {}) {
  const streams = streamIds.map(id => Number(id)).filter(id => Number.isInteger(id) && id > 0);
  if (!String(uniqueId || '').trim()) throw new Error('janus unique_id is required for Admin API stop_rtp_forward');
  if (streams.length === 0) throw new Error('at least one RTP forward stream_id is required');

  return compactObject({
    request: 'stop_rtp_forward',
    unique_id: String(uniqueId),
    admin_key: adminKey || undefined,
    streams
  });
}

function buildListForwardersRequest({ uniqueId, adminKey = '' } = {}) {
  if (!String(uniqueId || '').trim()) throw new Error('janus unique_id is required for Admin API listforwarders');

  return compactObject({
    request: 'listforwarders',
    unique_id: String(uniqueId),
    admin_key: adminKey || undefined
  });
}

function normalizeRtpStream(stream = {}) {
  const type = normalizeStreamType(stream.type);
  const host = String(stream.host || '').trim();
  const port = Number(stream.port);
  if (!host) throw new Error('RTP forward host is required');
  if (!Number.isInteger(port) || port <= 0 || port > 65535) throw new Error('RTP forward port must be a valid UDP port');

  return compactObject({
    type,
    host,
    host_family: stream.host_family || stream.hostFamily || undefined,
    port,
    ssrc: positiveInteger(stream.ssrc),
    pt: positiveInteger(stream.pt || stream.payload_type || stream.payloadType),
    srtp_suite: positiveInteger(stream.srtp_suite || stream.srtpSuite),
    srtp_crypto: stream.srtp_crypto || stream.srtpCrypto || undefined
  });
}

function normalizeStreamType(type = '') {
  const normalized = String(type || '').trim().toLowerCase().replace(/[-\s]+/g, '_');
  if (!VALID_STREAM_TYPES.has(normalized)) {
    throw new Error(`invalid RTP forward stream type: ${type}`);
  }
  return normalized;
}

function extractForwarderStreamIds(response = {}) {
  const forwarders = response.forwarders || response.rtp_forwarders || response.result?.forwarders || response.result?.rtp_forwarders || [];
  return forwarders
    .map(forwarder => Number(forwarder.stream_id || forwarder.streamId))
    .filter(id => Number.isInteger(id) && id > 0);
}

function positiveInteger(value) {
  if (value === undefined || value === null || value === '') return undefined;
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}

function compactObject(object) {
  return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = {
  VALID_STREAM_TYPES,
  JanusSipRtpForwardController,
  buildRtpForwardRequest,
  buildStopRtpForwardRequest,
  buildListForwardersRequest,
  extractForwarderStreamIds,
  normalizeRtpStream
};
