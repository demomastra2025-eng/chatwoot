const assert = require('node:assert/strict');
const test = require('node:test');

const {
  JanusSipRtpForwardController,
  buildListForwardersRequest,
  buildRtpForwardRequest,
  buildStopRtpForwardRequest,
  extractForwarderStreamIds,
  normalizeRtpStream
} = require('../src/janus/rtp-forward');

test('buildRtpForwardRequest follows Janus SIP rtp_forward Admin API shape', () => {
  assert.deepEqual(
    buildRtpForwardRequest({
      uniqueId: 'sip-handle-unique',
      adminKey: 'sip-admin',
      streams: [
        {
          type: 'peer-audio',
          host: 'janus-ai-gateway',
          hostFamily: 'ipv4',
          port: 40000,
          payloadType: 0
        }
      ]
    }),
    {
      request: 'rtp_forward',
      unique_id: 'sip-handle-unique',
      admin_key: 'sip-admin',
      streams: [
        {
          type: 'peer_audio',
          host: 'janus-ai-gateway',
          host_family: 'ipv4',
          port: 40000
        }
      ]
    }
  );
});

test('stop and list requests include unique_id for Janus Admin API', () => {
  assert.deepEqual(buildStopRtpForwardRequest({
    uniqueId: 'sip-handle-unique',
    streamIds: [1001, '1002', 0, 'bad']
  }), {
    request: 'stop_rtp_forward',
    unique_id: 'sip-handle-unique',
    streams: [1001, 1002]
  });

  assert.deepEqual(buildListForwardersRequest({ uniqueId: 'sip-handle-unique' }), {
    request: 'listforwarders',
    unique_id: 'sip-handle-unique'
  });
});

test('normalizeRtpStream validates Janus SIP stream types and UDP ports', () => {
  assert.deepEqual(normalizeRtpStream({ type: 'peer audio', host: '127.0.0.1', port: 49152, pt: 8 }), {
    type: 'peer_audio',
    host: '127.0.0.1',
    port: 49152,
    pt: 8
  });
  assert.throws(() => normalizeRtpStream({ type: 'metadata', host: '127.0.0.1', port: 49152 }), /invalid RTP forward stream type/);
  assert.throws(() => normalizeRtpStream({ type: 'peer_audio', host: '127.0.0.1', port: 70000 }), /valid UDP port/);
});

test('JanusSipRtpForwardController uses configured default peer audio stream', async () => {
  const calls = [];
  const controller = new JanusSipRtpForwardController({
    client: {
      async messagePlugin(payload) {
        calls.push(payload);
        return { forwarders: [{ stream_id: 1234 }] };
      }
    },
    adminKey: 'sip-admin',
    defaultHost: 'janus-ai-gateway',
    defaultHostFamily: 'ipv4',
    defaultPeerAudioPort: 40000,
    defaultPayloadType: 8
  });

  const response = await controller.startForwarders({
    uniqueId: 'sip-handle-unique',
    sessionId: '1',
    handleId: '2'
  });

  assert.deepEqual(response, { forwarders: [{ stream_id: 1234 }] });
  assert.equal(calls[0].sessionId, '1');
  assert.equal(calls[0].handleId, '2');
  assert.deepEqual(calls[0].request, {
    request: 'rtp_forward',
    unique_id: 'sip-handle-unique',
    admin_key: 'sip-admin',
    streams: [{
      type: 'peer_audio',
      host: 'janus-ai-gateway',
      host_family: 'ipv4',
      port: 40000,
      pt: 8
    }]
  });
});

test('extractForwarderStreamIds supports Janus response variants', () => {
  assert.deepEqual(extractForwarderStreamIds({
    result: {
      rtp_forwarders: [{ stream_id: 1 }, { streamId: 2 }, { stream_id: 'bad' }]
    }
  }), [1, 2]);
});
