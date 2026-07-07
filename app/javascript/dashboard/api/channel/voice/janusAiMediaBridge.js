const INPUT_RATE = 16000;
const OUTPUT_RATE = 8000;
const PROCESSOR_SIZE = 1024;
const START_BUFFER_SECONDS = 0.04;
const MAX_OUTPUT_QUEUE_SECONDS = 0.6;
const INPUT_GAIN = 1.8;
const OUTPUT_GAIN = 1.08;
const REMOTE_MONITOR_GAIN = 0.00001;

const clampSample = value => Math.max(-1, Math.min(1, value));
const softLimitSample = value => Math.tanh(value * 1.1) / Math.tanh(1.1);

const parseSampleRate = (mimeType, fallback) => {
  const match = String(mimeType || '').match(/rate\s*=\s*(\d+)/i);
  if (!match) return fallback;

  const rate = Number.parseInt(match[1], 10);
  return Number.isFinite(rate) && rate > 0 ? rate : fallback;
};

const base64ToBytes = value => {
  const binary = window.atob(String(value || ''));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
};

const bytesToBase64 = bytes => {
  let binary = '';
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return window.btoa(binary);
};

const pcm16BytesToFloat32 = bytes => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const output = new Float32Array(Math.floor(bytes.byteLength / 2));
  for (let i = 0; i < output.length; i += 1) {
    output[i] = view.getInt16(i * 2, true) / 32768;
  }
  return output;
};

const float32ToPcm16Bytes = samples => {
  const bytes = new Uint8Array(samples.length * 2);
  const view = new DataView(bytes.buffer);
  for (let i = 0; i < samples.length; i += 1) {
    const sample = clampSample(samples[i]);
    view.setInt16(i * 2, sample < 0 ? sample * 32768 : sample * 32767, true);
  }
  return bytes;
};

const resampleLinear = (input, fromRate, toRate) => {
  if (!input.length || fromRate === toRate) return input;
  const ratio = fromRate / toRate;
  const outputLength = Math.max(1, Math.floor(input.length / ratio));
  const output = new Float32Array(outputLength);
  for (let i = 0; i < outputLength; i += 1) {
    const sourceIndex = i * ratio;
    const left = Math.floor(sourceIndex);
    const right = Math.min(left + 1, input.length - 1);
    const weight = sourceIndex - left;
    output[i] = input[left] * (1 - weight) + input[right] * weight;
  }
  return output;
};

const applyOutputGain = samples => {
  if (!samples.length || OUTPUT_GAIN === 1) return samples;

  const output = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i += 1) {
    output[i] = clampSample(softLimitSample(samples[i] * OUTPUT_GAIN));
  }
  return output;
};

const applyInputGain = samples => {
  if (!samples.length || INPUT_GAIN === 1) return samples;

  const output = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i += 1) {
    output[i] = clampSample(softLimitSample(samples[i] * INPUT_GAIN));
  }
  return output;
};

const mixedInputSamples = inputBuffer => {
  const channelCount = Math.max(1, inputBuffer.numberOfChannels || 1);
  const length = inputBuffer.length || inputBuffer.getChannelData(0).length;
  const output = new Float32Array(length);
  let activeChannelCount = 0;

  for (let channel = 0; channel < channelCount; channel += 1) {
    const data = inputBuffer.getChannelData(channel);
    let channelHasSignal = false;
    for (let i = 0; i < length; i += 1) {
      const sample = data[i] || 0;
      if (sample !== 0) channelHasSignal = true;
      output[i] += sample;
    }
    if (channelHasSignal) activeChannelCount += 1;
  }

  if (channelCount === 1) return output;
  const divisor = activeChannelCount || channelCount;
  for (let i = 0; i < output.length; i += 1) output[i] /= divisor;
  return output;
};

export default class JanusAiMediaBridge {
  constructor({
    streamUrl,
    AudioContextImpl = null,
    WebSocketImpl = null,
  } = {}) {
    if (!streamUrl) throw new Error('ai_stream_url_required');
    const AudioContextConstructor =
      AudioContextImpl ||
      (typeof window !== 'undefined'
        ? window.AudioContext || window.webkitAudioContext
        : null);
    if (!AudioContextConstructor) throw new Error('audio_context_unavailable');

    this.streamUrl = streamUrl;
    this.WebSocketImpl =
      WebSocketImpl ||
      (typeof window !== 'undefined' ? window.WebSocket : null);
    if (!this.WebSocketImpl) throw new Error('websocket_unavailable');
    this.audioContext = new AudioContextConstructor({
      latencyHint: 'interactive',
    });
    this.destination = this.audioContext.createMediaStreamDestination();
    this.ws = null;
    this.remoteSource = null;
    this.remoteProcessor = null;
    this.remoteMonitorGain = null;
    this.remoteAudioElement = null;
    this.remoteStream = null;
    this.closed = false;
    this.outputCursor = 0;
    this.outputSources = new Set();
    this.resumeTimer = null;
  }

  outputTrack() {
    return this.destination.stream.getAudioTracks()[0] || null;
  }

  async start() {
    await this.ensureRunning();
    this.ws = new this.WebSocketImpl(this.streamUrl);
    this.ws.onmessage = event => this.handleMessage(event.data);
    this.ws.onclose = () => this.close({ closeSocket: false });
    return new Promise((resolve, reject) => {
      this.ws.onopen = () => resolve(this);
      this.ws.onerror = error => reject(error);
    });
  }

  async ensureRunning({ retries = 0 } = {}) {
    if (this.closed) return false;

    const state = this.audioContext.state;
    if (!state || state === 'running') return true;

    try {
      await this.audioContext.resume?.();
    } catch {
      // Browser autoplay policy can temporarily block resume; retry below.
    }

    if (!this.audioContext.state || this.audioContext.state === 'running') {
      return true;
    }

    if (retries > 0 && typeof window !== 'undefined') {
      this.clearResumeTimer();
      this.resumeTimer = window.setTimeout(() => {
        this.resumeTimer = null;
        this.ensureRunning({ retries: retries - 1 }).catch(() => {});
      }, 120);
    }

    return false;
  }

  clearResumeTimer() {
    if (!this.resumeTimer || typeof window === 'undefined') return;

    window.clearTimeout(this.resumeTimer);
    this.resumeTimer = null;
  }

  attachRemoteStream(stream) {
    if (this.closed || !stream) return;
    if (stream === this.remoteStream && this.remoteProcessor) {
      this.ensureRunning({ retries: 8 }).catch(() => {});
      return;
    }

    this.disconnectRemoteStream();
    this.remoteStream = stream;
    this.attachRemoteAudioElement(stream);
    this.ensureRunning({ retries: 8 }).catch(() => {});
    this.remoteSource = this.audioContext.createMediaStreamSource(stream);
    this.remoteProcessor = this.audioContext.createScriptProcessor(
      PROCESSOR_SIZE,
      2,
      1
    );
    this.remoteProcessor.onaudioprocess = event => {
      const openState = this.WebSocketImpl.OPEN ?? 1;
      if (this.ws?.readyState !== openState) return;
      const input = applyInputGain(mixedInputSamples(event.inputBuffer));
      const resampled = resampleLinear(
        input,
        this.audioContext.sampleRate,
        INPUT_RATE
      );
      const data = bytesToBase64(float32ToPcm16Bytes(resampled));
      this.ws.send(
        JSON.stringify({
          type: 'AUDIO_IN',
          data,
          mime_type: `audio/pcm;rate=${INPUT_RATE}`,
        })
      );
    };
    this.remoteMonitorGain = this.audioContext.createGain();
    this.remoteMonitorGain.gain.value = REMOTE_MONITOR_GAIN;
    this.remoteSource.connect(this.remoteProcessor);
    this.remoteProcessor.connect(this.remoteMonitorGain);
    this.remoteMonitorGain.connect(this.audioContext.destination);
  }

  attachRemoteAudioElement(stream) {
    if (typeof document === 'undefined' || !document.createElement) return;

    const audio = document.createElement('audio');
    audio.autoplay = true;
    audio.muted = true;
    audio.playsInline = true;
    audio.style.display = 'none';
    audio.srcObject = stream;
    document.body?.appendChild?.(audio);
    const playResult = audio.play?.();
    playResult?.catch?.(() => {});
    this.remoteAudioElement = audio;
  }

  detachRemoteAudioElement() {
    if (!this.remoteAudioElement) return;

    try {
      this.remoteAudioElement.pause?.();
      if ('srcObject' in this.remoteAudioElement) {
        this.remoteAudioElement.srcObject = null;
      }
      this.remoteAudioElement.removeAttribute?.('src');
      this.remoteAudioElement.load?.();
      this.remoteAudioElement.remove?.();
    } catch {
      // Hidden audio sink cleanup must not interrupt SIP media teardown.
    }
    this.remoteAudioElement = null;
  }

  handleMessage(message) {
    if (this.closed) return;
    let payload;
    try {
      payload = JSON.parse(String(message || ''));
    } catch {
      return;
    }
    if (!payload?.data || payload.type !== 'AUDIO_OUT') return;
    const pcm = pcm16BytesToFloat32(base64ToBytes(payload.data));
    const outputRate = parseSampleRate(
      payload.mime_type || payload.mimeType,
      OUTPUT_RATE
    );
    const samples = applyOutputGain(
      resampleLinear(pcm, outputRate, this.audioContext.sampleRate)
    );
    const buffer = this.audioContext.createBuffer(
      1,
      samples.length,
      this.audioContext.sampleRate
    );
    buffer.copyToChannel(samples, 0);
    const source = this.audioContext.createBufferSource();
    source.buffer = buffer;
    source.connect(this.destination);
    const now = this.audioContext.currentTime;
    if (this.outputCursor - now > MAX_OUTPUT_QUEUE_SECONDS) {
      this.clearQueuedOutput();
      this.outputCursor = now + START_BUFFER_SECONDS;
    }
    this.outputCursor = Math.max(
      this.outputCursor || now + START_BUFFER_SECONDS,
      now
    );
    this.outputSources.add(source);
    source.onended = () => this.outputSources.delete(source);
    source.start(this.outputCursor);
    this.outputCursor += buffer.duration;
  }

  clearQueuedOutput() {
    this.outputSources.forEach(source => {
      try {
        source.stop?.();
      } catch {
        // Already ended sources are safe to ignore.
      }
    });
    this.outputSources.clear();
  }

  disconnectRemoteStream() {
    this.clearResumeTimer();
    try {
      this.remoteProcessor?.disconnect?.();
      this.remoteSource?.disconnect?.();
      this.remoteMonitorGain?.disconnect?.();
    } catch {
      // Best-effort cleanup; call teardown must continue.
    }
    if (this.remoteProcessor) this.remoteProcessor.onaudioprocess = null;
    this.detachRemoteAudioElement();
    this.remoteProcessor = null;
    this.remoteMonitorGain = null;
    this.remoteSource = null;
    this.remoteStream = null;
  }

  close({ closeSocket = true } = {}) {
    if (this.closed) return;
    this.closed = true;
    this.clearQueuedOutput();
    this.disconnectRemoteStream();
    if (closeSocket) this.ws?.close?.();
    this.ws = null;
    this.destination.stream.getTracks().forEach(track => track.stop());
    this.audioContext.close?.().catch?.(() => {});
  }
}
