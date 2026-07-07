const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const WebSocket = require('ws');
const {
  JanusBrowserBridgeManager,
  createJanusBrowserBridgeMediaStreamFactory
} = require('../src/janus/browser-bridge');

function listen(server) {
  return new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
}

function once(emitter, event) {
  return new Promise(resolve => emitter.once(event, resolve));
}

test('Janus browser bridge exchanges browser audio with the runtime media stream', async () => {
  const server = http.createServer((_req, res) => {
    res.writeHead(404);
    res.end();
  });
  const manager = new JanusBrowserBridgeManager({
    publicBaseUrl: 'ws://placeholder.local'
  });
  server.on('upgrade', (req, socket, head) => {
    if (!manager.handleUpgrade(req, socket, head)) socket.destroy();
  });
  await listen(server);

  const session = manager.createSession({
    callRef: 'sipuni:janus-ai:test',
    streamRef: 'stream-1',
    mediaSessionRef: 'media-1'
  });
  const factory = createJanusBrowserBridgeMediaStreamFactory({ manager });
  const mediaStream = await factory({
    request: {
      runtime_stream: {
        kind: 'browser_janus_bridge',
        runtime_session_id: session.id
      }
    }
  });
  const streamUrl = manager
    .streamUrlForSession(session)
    .replace('ws://placeholder.local', `ws://127.0.0.1:${server.address().port}`);
  const ws = new WebSocket(streamUrl);
  await once(ws, 'open');

  const payloadPromise = once(mediaStream, 'payload');
  ws.send(JSON.stringify({
    type: 'AUDIO_IN',
    data: Buffer.from([1, 2, 3, 4]).toString('base64'),
    mime_type: 'audio/pcm;rate=16000'
  }));
  const payload = await payloadPromise;

  assert.deepEqual([...payload.data], [1, 2, 3, 4]);
  assert.equal(payload.mimeType, 'audio/pcm;rate=16000');
  assert.equal(payload.streamRef, 'stream-1');
  assert.equal(payload.mediaSessionRef, 'media-1');
  assert.equal(payload.transport, 'janus_sip');

  const outboundPromise = once(ws, 'message');
  mediaStream.write({
    data: Buffer.from([5, 6]),
    mimeType: 'audio/pcm;rate=8000'
  });
  const outbound = JSON.parse(String(await outboundPromise));

  assert.equal(outbound.type, 'AUDIO_OUT');
  assert.equal(outbound.data, Buffer.from([5, 6]).toString('base64'));
  assert.equal(outbound.mime_type, 'audio/pcm;rate=8000');

  ws.close();
  await new Promise(resolve => server.close(resolve));
});
