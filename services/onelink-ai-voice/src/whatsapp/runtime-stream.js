const {
  DEFAULT_INPUT_MIME_TYPE,
  DEFAULT_OUTPUT_TYPE,
  DEFAULT_INPUT_TYPE,
  WebsocketRuntimeMediaStream,
  createWebsocketRuntimeMediaStreamFactory
} = require('../runtime/websocket-media-stream');

function createWhatsappRuntimeMediaStreamFactory({ WebSocketImpl } = {}) {
  return createWebsocketRuntimeMediaStreamFactory({
    WebSocketImpl,
    runtimeStreamKey: 'runtime_stream'
  });
}

module.exports = {
  DEFAULT_INPUT_MIME_TYPE,
  DEFAULT_OUTPUT_TYPE,
  DEFAULT_INPUT_TYPE,
  WhatsappRuntimeMediaStream: WebsocketRuntimeMediaStream,
  createWhatsappRuntimeMediaStreamFactory
};
