const { EventEmitter } = require('node:events');

const defaultConstants = loadStreamConstants();

async function startManagedVoiceStream(call, options = {}) {
  const internals = options.internals || loadFonosterInternals();
  const { internals: _ignoredInternals, ...streamOptions } = options;
  const mediaSessionRef = mediaSessionRefFor(call, streamOptions);
  const format = streamOptions.format || defaultConstants.wavFormat;

  if (canUseNativeManagedStream(call, internals)) {
    const stream = new internals.Stream();
    const startStream = new internals.StartStream(call.request, call.voice);
    const stopStream = new internals.StopStream(call.request, call.voice);
    const response = await startStream.run({
      mediaSessionRef,
      ...streamOptions
    });
    const streamRef = trimText(response?.startStreamResponse?.streamRef || response?.streamRef || streamOptions.streamRef || '');

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
    wireStreamWrites(stream, call.voice, { mediaSessionRef, streamRef, format });
    patchStreamClose(stream, call.voice, onData, stopStream, { mediaSessionRef, streamRef });
    return stream;
  }

  if (!call || typeof call.stream !== 'function') return null;
  return call.stream(streamOptions);
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

function wireStreamWrites(stream, voiceTransport, defaults) {
  const writePayload = payload => {
    voiceTransport.write({
      streamPayload: {
        ...payload,
        mediaSessionRef: payload.mediaSessionRef || defaults.mediaSessionRef,
        streamRef: payload.streamRef || defaults.streamRef,
        format: payload.format || defaults.format
      }
    });
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
      wavFormat: common.StreamAudioFormat?.WAV || 'wav'
    };
  } catch (_error) {
    return { wavFormat: 'wav' };
  }
}

function trimText(value) {
  return String(value || '').trim();
}

module.exports = { startManagedVoiceStream, loadFonosterInternals, loadFonosterInternalsFrom, canUseNativeManagedStream };
