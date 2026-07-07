const {
  WebsocketRuntimeMediaStream,
  createWebsocketRuntimeMediaStreamFactory
} = require('../runtime/websocket-media-stream');

function createJanusRuntimeMediaStreamFactory({ WebSocketImpl } = {}) {
  return createWebsocketRuntimeMediaStreamFactory({
    WebSocketImpl,
    transport: 'janus_sip',
    runtimeStreamKey: 'runtime_stream'
  });
}

module.exports = {
  JanusRuntimeMediaStream: WebsocketRuntimeMediaStream,
  createJanusRuntimeMediaStreamFactory
};
