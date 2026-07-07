const RTP_HEADER_BYTES = 12;
const DEFAULT_PCMU_PAYLOAD_TYPE = 0;
const DEFAULT_PCMA_PAYLOAD_TYPE = 8;

function parseRtpPacket(packet) {
  const buffer = Buffer.isBuffer(packet) ? packet : Buffer.from(packet || []);
  if (buffer.length < RTP_HEADER_BYTES) return null;

  const version = buffer[0] >> 6;
  if (version !== 2) return null;

  const csrcCount = buffer[0] & 0x0f;
  const hasExtension = Boolean(buffer[0] & 0x10);
  const headerBytes = RTP_HEADER_BYTES + (csrcCount * 4);
  if (buffer.length < headerBytes) return null;

  let payloadOffset = headerBytes;
  if (hasExtension) {
    if (buffer.length < payloadOffset + 4) return null;
    const extensionLengthWords = buffer.readUInt16BE(payloadOffset + 2);
    payloadOffset += 4 + (extensionLengthWords * 4);
    if (buffer.length < payloadOffset) return null;
  }

  return {
    marker: Boolean(buffer[1] & 0x80),
    payloadType: buffer[1] & 0x7f,
    sequenceNumber: buffer.readUInt16BE(2),
    timestamp: buffer.readUInt32BE(4),
    ssrc: buffer.readUInt32BE(8),
    payload: buffer.subarray(payloadOffset)
  };
}

function buildRtpPacket({
  payload,
  payloadType = DEFAULT_PCMU_PAYLOAD_TYPE,
  sequenceNumber = 0,
  timestamp = 0,
  ssrc = 0,
  marker = false
} = {}) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || []);
  const packet = Buffer.alloc(RTP_HEADER_BYTES + body.length);
  packet[0] = 0x80;
  packet[1] = (marker ? 0x80 : 0) | (payloadType & 0x7f);
  packet.writeUInt16BE(sequenceNumber & 0xffff, 2);
  packet.writeUInt32BE(timestamp >>> 0, 4);
  packet.writeUInt32BE(ssrc >>> 0, 8);
  body.copy(packet, RTP_HEADER_BYTES);
  return packet;
}

function decodeTelephonyPayload(payload, codec = 'pcmu') {
  const normalized = normalizeCodec(codec);
  if (normalized === 'pcma') return decodePcma(payload);
  if (normalized === 'l16') return Buffer.from(payload || []);
  return decodePcmu(payload);
}

function encodeTelephonyPayload(pcm16, codec = 'pcmu') {
  const normalized = normalizeCodec(codec);
  if (normalized === 'pcma') return encodePcma(pcm16);
  if (normalized === 'l16') return Buffer.from(pcm16 || []);
  return encodePcmu(pcm16);
}

function decodePcmu(payload) {
  const input = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || []);
  const output = Buffer.alloc(input.length * 2);
  for (let index = 0; index < input.length; index += 1) {
    output.writeInt16LE(mulawDecodeSample(input[index]), index * 2);
  }
  return output;
}

function encodePcmu(pcm16) {
  const input = evenPcm16(pcm16);
  const output = Buffer.alloc(input.length / 2);
  for (let index = 0; index < output.length; index += 1) {
    output[index] = mulawEncodeSample(input.readInt16LE(index * 2));
  }
  return output;
}

function decodePcma(payload) {
  const input = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || []);
  const output = Buffer.alloc(input.length * 2);
  for (let index = 0; index < input.length; index += 1) {
    output.writeInt16LE(alawDecodeSample(input[index]), index * 2);
  }
  return output;
}

function encodePcma(pcm16) {
  const input = evenPcm16(pcm16);
  const output = Buffer.alloc(input.length / 2);
  for (let index = 0; index < output.length; index += 1) {
    output[index] = alawEncodeSample(input.readInt16LE(index * 2));
  }
  return output;
}

function upsamplePcm16By2(pcm16) {
  const input = evenPcm16(pcm16);
  const output = Buffer.alloc(input.length * 2);
  for (let inputOffset = 0, outputOffset = 0; inputOffset < input.length; inputOffset += 2, outputOffset += 4) {
    const sample = input.readInt16LE(inputOffset);
    output.writeInt16LE(sample, outputOffset);
    output.writeInt16LE(sample, outputOffset + 2);
  }
  return output;
}

function downsamplePcm16By2(pcm16) {
  const input = evenPcm16(pcm16);
  const samples = Math.floor(input.length / 4);
  const output = Buffer.alloc(samples * 2);
  for (let index = 0; index < samples; index += 1) {
    output.writeInt16LE(input.readInt16LE(index * 4), index * 2);
  }
  return output;
}

function normalizeCodec(codec = '') {
  const value = String(codec || '').trim().toLowerCase().replace(/[-_\s]+/g, '');
  if (['pcma', 'alaw', 'g711a', 'g711alaw'].includes(value)) return 'pcma';
  if (['l16', 'pcm16', 'linear16', 'pcm'].includes(value)) return 'l16';
  return 'pcmu';
}

function payloadTypeForCodec(codec = '') {
  const normalized = normalizeCodec(codec);
  if (normalized === 'pcma') return DEFAULT_PCMA_PAYLOAD_TYPE;
  return DEFAULT_PCMU_PAYLOAD_TYPE;
}

function evenPcm16(pcm16) {
  const buffer = Buffer.isBuffer(pcm16) ? pcm16 : Buffer.from(pcm16 || []);
  return buffer.subarray(0, buffer.length - (buffer.length % 2));
}

function mulawDecodeSample(byte) {
  const value = (~byte) & 0xff;
  const sign = value & 0x80;
  const exponent = (value >> 4) & 0x07;
  const mantissa = value & 0x0f;
  let sample = ((mantissa << 3) + 0x84) << exponent;
  sample -= 0x84;
  return sign ? -sample : sample;
}

function mulawEncodeSample(sample) {
  const BIAS = 0x84;
  const CLIP = 32635;
  let value = Math.max(-CLIP, Math.min(CLIP, sample));
  const sign = value < 0 ? 0x80 : 0;
  if (value < 0) value = -value;
  value += BIAS;

  let exponent = 7;
  for (let mask = 0x4000; (value & mask) === 0 && exponent > 0; mask >>= 1) {
    exponent -= 1;
  }
  const mantissa = (value >> (exponent + 3)) & 0x0f;
  return (~(sign | (exponent << 4) | mantissa)) & 0xff;
}

function alawDecodeSample(byte) {
  const value = byte ^ 0x55;
  const sign = value & 0x80;
  const exponent = (value & 0x70) >> 4;
  const mantissa = value & 0x0f;
  let sample = mantissa << 4;
  if (exponent === 0) sample += 8;
  else if (exponent === 1) sample += 0x108;
  else {
    sample += 0x108;
    sample <<= exponent - 1;
  }
  return sign ? sample : -sample;
}

function alawEncodeSample(sample) {
  let value = Math.max(-32635, Math.min(32635, sample));
  const sign = value >= 0 ? 0x80 : 0;
  if (value < 0) value = -value - 1;

  let compressed;
  if (value < 256) {
    compressed = sign | (value >> 4);
  } else {
    let exponent = 7;
    for (let mask = 0x4000; (value & mask) === 0 && exponent > 0; mask >>= 1) {
      exponent -= 1;
    }
    compressed = sign | (exponent << 4) | ((value >> (exponent + 3)) & 0x0f);
  }
  return compressed ^ 0x55;
}

module.exports = {
  DEFAULT_PCMA_PAYLOAD_TYPE,
  DEFAULT_PCMU_PAYLOAD_TYPE,
  buildRtpPacket,
  decodePcma,
  decodePcmu,
  decodeTelephonyPayload,
  downsamplePcm16By2,
  encodePcma,
  encodePcmu,
  encodeTelephonyPayload,
  normalizeCodec,
  parseRtpPacket,
  payloadTypeForCodec,
  upsamplePcm16By2
};
