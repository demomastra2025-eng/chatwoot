function assertPipecatRuntimeStream(request = {}) {
  const runtimeStream = request.runtime_stream || request.runtimeStream || {};
  let streamUrl = null;
  try {
    streamUrl = new URL(String(runtimeStream.stream_url || runtimeStream.streamUrl || ''));
  } catch (_error) {
    streamUrl = null;
  }

  if (
    String(runtimeStream.runtime_session_id || runtimeStream.runtimeSessionId || '').trim() &&
    streamUrl &&
    ['ws:', 'wss:'].includes(streamUrl.protocol) &&
    !streamUrl.search &&
    String(runtimeStream.stream_token || runtimeStream.streamToken || '').trim() &&
    runtimeStream.codec === 'pcm_s16le' &&
    runtimeStream.input_sample_rate === 16000 &&
    runtimeStream.output_sample_rate === 8000
  ) return;

  const error = new Error('Pipecat requires a prepared runtime media stream');
  error.code = 'pipecat_runtime_stream_required';
  error.statusCode = 422;
  throw error;
}

module.exports = { assertPipecatRuntimeStream };
