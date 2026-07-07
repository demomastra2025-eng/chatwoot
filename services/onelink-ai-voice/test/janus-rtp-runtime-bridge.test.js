const assert = require('node:assert/strict');
const EventEmitter = require('node:events');
const test = require('node:test');

const { JanusRtpRuntimeBridgeManager, createJanusRtpBridgeMediaStreamFactory } = require('../src/janus/rtp-runtime-bridge');
const { buildRtpPacket, encodePcmu, parseRtpPacket } = require('../src/janus/rtp-packet');

class FakeUdpSocket extends EventEmitter {
  constructor() {
    super();
    this.sent = [];
    this.bound = null;
  }

  bind(port, host) {
    this.bound = { port, host };
    queueMicrotask(() => this.emit('listening'));
  }

  address() {
    return { port: this.bound?.port || 40000 };
  }

  send(packet, port, host) {
    this.sent.push({ packet, port, host });
  }

  close() {
    this.closed = true;
  }
}

function fakeDgram() {
  const sockets = [];
  return {
    sockets,
    createSocket() {
      const socket = new FakeUdpSocket();
      sockets.push(socket);
      return socket;
    }
  };
}

test('Janus RTP bridge emits AUDIO_IN from incoming PCMU RTP packets', async () => {
  const dgramImpl = fakeDgram();
  const manager = new JanusRtpRuntimeBridgeManager({
    enabled: true,
    listenPort: 40000,
    publicHost: 'onelink_ai_voice',
    dgramImpl
  });
  const session = await manager.createSession({
    callRef: 'janus-call-1',
    inboundSsrc: 1111
  });

  let payload;
  session.mediaStream.onPayload(item => { payload = item; });

  const pcm8 = Buffer.alloc(320);
  pcm8.writeInt16LE(1000, 0);
  const packet = buildRtpPacket({
    payload: encodePcmu(pcm8),
    payloadType: 0,
    sequenceNumber: 1,
    timestamp: 160,
    ssrc: 1111
  });
  dgramImpl.sockets[0].emit('message', packet, { address: 'janus_gateway', port: 50000 });

  assert.equal(payload.type, 'AUDIO_IN');
  assert.equal(payload.mimeType, 'audio/pcm;rate=16000');
  assert.equal(payload.transport, 'janus_sip');
  assert.equal(payload.data.length, 640);
});

test('Janus RTP bridge sends AUDIO_OUT to configured RTP output target', async () => {
  const dgramImpl = fakeDgram();
  const manager = new JanusRtpRuntimeBridgeManager({
    enabled: true,
    listenPort: 40000,
    outputHost: 'janus_nosip',
    outputPort: 41000,
    dgramImpl
  });
  const session = await manager.createSession({
    callRef: 'janus-call-2',
    inboundSsrc: 2222,
    output: { ssrc: 3333 }
  });

  const pcm16 = Buffer.alloc(640);
  pcm16.writeInt16LE(1000, 0);
  const result = session.mediaStream.write({ type: 'AUDIO_OUT', data: pcm16 });

  assert.equal(result, true);
  assert.equal(dgramImpl.sockets[0].sent.length, 1);
  assert.equal(dgramImpl.sockets[0].sent[0].host, 'janus_nosip');
  assert.equal(dgramImpl.sockets[0].sent[0].port, 41000);
  const packet = parseRtpPacket(dgramImpl.sockets[0].sent[0].packet);
  assert.equal(packet.ssrc, 3333);
  assert.equal(packet.payloadType, 0);
  assert.equal(packet.payload.length, 160);
});

test('createJanusRtpBridgeMediaStreamFactory returns in-process bridge sessions', async () => {
  const dgramImpl = fakeDgram();
  const manager = new JanusRtpRuntimeBridgeManager({ enabled: true, listenPort: 40000, dgramImpl });
  const session = await manager.createSession({ callRef: 'janus-call-3', inboundSsrc: 4444 });
  const factory = createJanusRtpBridgeMediaStreamFactory({ manager });

  const stream = await factory({
    request: {
      transport: 'janus_sip',
      runtime_stream: {
        kind: 'janus_rtp_bridge',
        runtime_session_id: session.id
      }
    }
  });

  assert.equal(stream, session.mediaStream);
});
