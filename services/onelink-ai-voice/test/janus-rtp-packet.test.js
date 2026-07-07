const assert = require('node:assert/strict');
const test = require('node:test');

const {
  buildRtpPacket,
  decodePcmu,
  encodePcmu,
  parseRtpPacket,
  upsamplePcm16By2,
  downsamplePcm16By2
} = require('../src/janus/rtp-packet');

test('buildRtpPacket and parseRtpPacket preserve RTP metadata and payload', () => {
  const payload = Buffer.from([0xff, 0x7f, 0x00]);
  const packet = buildRtpPacket({
    payload,
    payloadType: 0,
    sequenceNumber: 42,
    timestamp: 160,
    ssrc: 1234,
    marker: true
  });

  const parsed = parseRtpPacket(packet);
  assert.equal(parsed.marker, true);
  assert.equal(parsed.payloadType, 0);
  assert.equal(parsed.sequenceNumber, 42);
  assert.equal(parsed.timestamp, 160);
  assert.equal(parsed.ssrc, 1234);
  assert.deepEqual(parsed.payload, payload);
});

test('G.711 PCMU codec converts between telephony payload and PCM16', () => {
  const pcm = Buffer.alloc(320);
  for (let index = 0; index < pcm.length / 2; index += 1) {
    pcm.writeInt16LE(index % 2 === 0 ? 1000 : -1000, index * 2);
  }

  const encoded = encodePcmu(pcm);
  const decoded = decodePcmu(encoded);

  assert.equal(encoded.length, 160);
  assert.equal(decoded.length, 320);
  assert.ok(Math.abs(decoded.readInt16LE(0)) > 0);
});

test('simple PCM16 8k/16k conversion doubles and halves samples', () => {
  const pcm8 = Buffer.alloc(4);
  pcm8.writeInt16LE(100, 0);
  pcm8.writeInt16LE(-200, 2);

  const pcm16 = upsamplePcm16By2(pcm8);
  assert.deepEqual([...pcm16], [100, 0, 100, 0, 56, 255, 56, 255]);
  assert.deepEqual([...downsamplePcm16By2(pcm16)], [...pcm8]);
});
