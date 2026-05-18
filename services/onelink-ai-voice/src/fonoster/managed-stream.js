const { EventEmitter } = require('node:events');

const defaultConstants = loadStreamConstants();
const DEFAULT_START_STREAM_RESPONSE_TIMEOUT_MS = parsePositiveInteger(
  process.env.VOICE_AGENT_START_STREAM_RESPONSE_TIMEOUT_MS,
  3000
);

async function startManagedVoiceStream(call, options = {}) {
  const internals = options.internals || loadFonosterInternals();
  const {
    internals: _ignoredInternals,
    startStreamResponseTimeoutMs = DEFAULT_START_STREAM_RESPONSE_TIMEOUT_MS,
    onAudioOutWrite = null,
    ...streamOptions
  } = options;
  const mediaSessionRef = mediaSessionRefFor(call, streamOptions);
  const format = streamOptions.format || defaultConstants.wavFormat;

  if (canUseNativeManagedStream(call, internals)) {
    const stream = new internals.Stream();
    const startStream = new internals.StartStream(call.request, call.voice);
    const stopStream = new internals.StopStream(call.request, call.voice);
    const response = await waitForStartStreamResponse(
      startStream.run({
        mediaSessionRef,
        ...streamOptions
      }),
      startStreamResponseTimeoutMs,
      {
        onLateResolve: lateResponse => stopLateManagedStream(stopStream, lateResponse, {
          mediaSessionRef,
          streamRef: streamOptions.streamRef
        })
      }
    );
    const streamRef = trimText(response?.startStreamResponse?.streamRef || response?.streamRef || streamOptions.streamRef || '');
    if (!streamRef) throw startStreamContractError('start_stream_missing_stream_ref');

    stream.mediaSessionRef = mediaSessionRef;
    stream.streamRef = streamRef;
    stream.format = format;

    const onData = result => {
      const payload = result?.streamPayload || result?.payload || result;
      if (!payload) return;
      if (streamRef && payload.streamRef && payload.streamRef !== streamRef) return;
      emitPayload(stream, payload);
    };

    call.voice.on('data', onData);
    wireStreamWrites(stream, call.voice, { mediaSessionRef, streamRef, format }, { onAudioOutWrite });
    patchStreamClose(stream, call.voice, onData, stopStream, { mediaSessionRef, streamRef });
    return stream;
  }

  if (!call || typeof call.stream !== 'function') return null;
  return waitForStartStreamResponse(
    call.stream(streamOptions),
    startStreamResponseTimeoutMs,
    { onLateResolve: lateStream => closeLateStream(lateStream) }
  );
}

function canUseNativeManagedStream(call, internals = {}) {
  return Boolean(
    internals.StartStream &&
    internals.StopStream &&
    internals.Stream &&
    call?.request &&
    call?.voice &&
    typeof call.voice.on === 'function' &&
    typeof call.voice.write === 'function'
  );
}

function wireStreamWrites(stream, voiceTransport, defaults, { onAudioOutWrite = null } = {}) {
  const writePayload = payload => {
    const streamPayload = normalizeOutboundStreamPayload(payload, defaults);
    if (!streamPayload) return false;
    const writtenAt = new Date();
    const result = voiceTransport.write({ streamPayload });
    notifyAudioOutWrite(onAudioOutWrite, streamPayload, payload, writtenAt);
    return result;
  };

  if (typeof stream.onPayloadIn === 'function') {
    stream.onPayloadIn(writePayload);
    return;
  }

  if (typeof stream.write !== 'function') {
    stream.write = writePayload;
    return;
  }

  const originalWrite = stream.write.bind(stream);
  stream.write = payload => {
    try {
      return originalWrite(payload);
    } catch (_error) {
      return writePayload(payload);
    }
  };
}

function patchStreamClose(stream, voiceTransport, onData, stopStream, { mediaSessionRef, streamRef }) {
  const originalClose = typeof stream.close === 'function' ? stream.close.bind(stream) : null;
  let stopped = false;
  stream.close = () => {
    if (stopped) return;
    stopped = true;
    if (typeof voiceTransport.removeListener === 'function') voiceTransport.removeListener('data', onData);
    else if (typeof voiceTransport.off === 'function') voiceTransport.off('data', onData);
    if (streamRef && typeof stopStream?.run === 'function') {
      Promise.resolve(stopStream.run({ mediaSessionRef, streamRef })).catch(() => {});
    }
    originalClose?.();
  };
}

function emitPayload(stream, payload) {
  if (typeof stream.emit === 'function') {
    stream.emit('payloadOut', payload);
    stream.emit('payload', payload);
    return;
  }
  if (stream instanceof EventEmitter) stream.emit('payload', payload);
}

function normalizeOutboundStreamPayload(payload = {}, defaults = {}) {
  const data = normalizeBinaryPayload(payload.data);
  const type = normalizeStreamMessageType(payload.type, data);
  if (type !== defaultConstants.audioOut || !data || data.length === 0) return null;

  const streamPayload = {
    mediaSessionRef: payload.mediaSessionRef || defaults.mediaSessionRef,
    streamRef: payload.streamRef || defaults.streamRef,
    format: normalizeStreamFormat(payload.format || defaults.format),
    type,
    data
  };

  if (!streamPayload.mediaSessionRef || !streamPayload.streamRef) return null;
  return streamPayload;
}

function notifyAudioOutWrite(callback, streamPayload, sourcePayload = {}, writtenAt = new Date()) {
  if (typeof callback !== 'function') return;

  try {
    callback({
      first_audio_out_write_at: writtenAt.toISOString(),
      first_audio_out_write_bytes: streamPayload.data.length,
      first_audio_out_write_kind: sourcePayload.kind || sourcePayload.source || 'audio_out',
      first_audio_out_non_zero_ratio: nonZeroByteRatio(streamPayload.data),
      first_audio_out_rms: pcm16Rms(streamPayload.data),
      stream_ref: streamPayload.streamRef,
      media_session_ref: streamPayload.mediaSessionRef,
      format: streamPayload.format,
      type: streamPayload.type
    });
  } catch (_error) {
    // Telemetry callbacks must not break call audio writes.
  }
}

function nonZeroByteRatio(buffer) {
  if (!buffer?.length) return 0;
  let nonZero = 0;
  for (const byte of buffer) {
    if (byte !== 0) nonZero += 1;
  }
  return nonZero / buffer.length;
}

function pcm16Rms(buffer) {
  if (!buffer?.length || buffer.length < 2) return 0;
  let sumSquares = 0;
  let samples = 0;
  for (let index = 0; index + 1 < buffer.length; index += 2) {
    const sample = buffer.readInt16LE(index);
    sumSquares += sample * sample;
    samples += 1;
  }
  return samples > 0 ? Math.sqrt(sumSquares / samples) : 0;
}

function normalizeBinaryPayload(data) {
  if (data == null) return null;
  if (Buffer.isBuffer(data)) return data.length ? data : null;
  if (data instanceof Uint8Array) {
    const buffer = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
    return buffer.length ? buffer : null;
  }
  if (data instanceof ArrayBuffer) {
    const buffer = Buffer.from(data);
    return buffer.length ? buffer : null;
  }
  if (Array.isArray(data)) {
    const buffer = Buffer.from(data);
    return buffer.length ? buffer : null;
  }
  return null;
}

function normalizeStreamMessageType(type, data) {
  const normalized = String(type || (data ? defaultConstants.audioOut : '') || '')
    .trim()
    .replace(/[-\s]+/g, '_')
    .toUpperCase();
  if (normalized === 'AUDIOOUT') return defaultConstants.audioOut;
  if (normalized === 'AUDIO_OUT') return defaultConstants.audioOut;
  if (normalized === 'ERROR') return defaultConstants.errorType;
  return normalized || defaultConstants.audioOut;
}

function normalizeStreamFormat(format) {
  const normalized = String(format || defaultConstants.wavFormat || '')
    .trim()
    .toUpperCase();
  return normalized === 'WAV' ? defaultConstants.wavFormat : (normalized || defaultConstants.wavFormat);
}

async function waitForStartStreamResponse(responsePromise, timeoutMs, { onLateResolve = null } = {}) {
  const guardedResponsePromise = Promise.resolve(responsePromise);
  let timedOut = false;
  guardedResponsePromise.then(
    response => {
      if (!timedOut || typeof onLateResolve !== 'function') return;
      try {
        onLateResolve(response);
      } catch (_error) {
        // Late provider cleanup is best effort; the caller already failed fast.
      }
    },
    () => {}
  );

  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return guardedResponsePromise;

  let timeoutId;
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => {
      timedOut = true;
      const error = new Error('start_stream_response_timeout');
      error.code = 'start_stream_response_timeout';
      error.reason = 'start_stream_response_timeout';
      error.source = 'fonoster_start_stream';
      error.timeoutMs = timeoutMs;
      reject(error);
    }, timeoutMs);
  });

  try {
    return await Promise.race([guardedResponsePromise, timeout]);
  } finally {
    clearTimeout(timeoutId);
  }
}

function stopLateManagedStream(stopStream, response, { mediaSessionRef, streamRef: fallbackStreamRef } = {}) {
  const streamRef = trimText(response?.startStreamResponse?.streamRef || response?.streamRef || fallbackStreamRef || '');
  if (!streamRef || typeof stopStream?.run !== 'function') return;
  Promise.resolve(stopStream.run({ mediaSessionRef, streamRef })).catch(() => {});
}

function startStreamContractError(reason) {
  const error = new Error(reason);
  error.code = reason;
  error.reason = reason;
  error.source = 'fonoster_start_stream';
  return error;
}

function closeLateStream(stream) {
  try {
    stream?.close?.();
  } catch (_error) {
    // ignore late stream cleanup errors
  }
}

function mediaSessionRefFor(call, options = {}) {
  return options.mediaSessionRef || options.media_session_ref || call?.request?.mediaSessionRef || call?.request?.media_session_ref || call?.mediaSessionRef || call?.media_session_ref;
}

function loadFonosterInternals() {
  return loadFonosterInternalsFrom(require);
}

function loadFonosterInternalsFrom(loader) {
  const candidates = [
    '@fonoster/voice/dist/verbs/Stream',
    '@fonoster/voice/dist/verbs',
    '@fonoster/voice/dist/common/streams',
    '@fonoster/voice/dist/common/streams/index'
  ];

  for (const candidate of candidates) {
    try {
      const mod = loader(candidate);
      if (mod?.StartStream && mod?.StopStream && mod?.Stream) return mod;
    } catch (_error) {
      // Try the next known Fonoster SDK layout.
    }
  }
  return {};
}

function loadStreamConstants() {
  try {
    const common = require('@fonoster/common');
    return {
      wavFormat: common.StreamAudioFormat?.WAV || 'WAV',
      audioOut: common.StreamMessageType?.AUDIO_OUT || 'AUDIO_OUT',
      errorType: common.StreamMessageType?.ERROR || 'ERROR'
    };
  } catch (_error) {
    return { wavFormat: 'WAV', audioOut: 'AUDIO_OUT', errorType: 'ERROR' };
  }
}

function parsePositiveInteger(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function trimText(value) {
  return String(value || '').trim();
}

module.exports = { startManagedVoiceStream, loadFonosterInternals, loadFonosterInternalsFrom, canUseNativeManagedStream };
