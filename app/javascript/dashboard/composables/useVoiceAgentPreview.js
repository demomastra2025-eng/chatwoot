import { computed, onBeforeUnmount, ref } from 'vue';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';

const INPUT_SAMPLE_RATE = 16000;
const INPUT_FRAME_SAMPLES = 320;
const DEFAULT_OUTPUT_SAMPLE_RATE = 8000;
const OUTPUT_FRAME_DURATION_MS = 20;
const PCM_BYTES_PER_SAMPLE = Int16Array.BYTES_PER_ELEMENT;
const READY_TIMEOUT_MS = 10000;
const AUDIO_WORKLET_TIMEOUT_MS = 2000;

const bytesToBase64 = bytes => {
  let binary = '';
  bytes.forEach(byte => {
    binary += String.fromCharCode(byte);
  });
  return window.btoa(binary);
};

const base64ToInt16 = (value, expectedByteLength) => {
  if (typeof value !== 'string' || !value) {
    throw new Error('invalid_audio_payload');
  }
  const maxEncodedLength = Math.ceil(expectedByteLength / 3) * 4;
  if (value.length > maxEncodedLength) {
    throw new Error('invalid_audio_payload');
  }
  const binary = window.atob(value);
  const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
  if (bytes.byteLength !== expectedByteLength) {
    throw new Error('invalid_audio_payload');
  }
  return new Int16Array(bytes.buffer);
};

const resampleForOutput = (pcm, sourceRate, targetRate) => {
  const outputLength = Math.max(
    1,
    Math.round((pcm.length * targetRate) / sourceRate)
  );
  const output = new Float32Array(outputLength);
  const rateRatio = sourceRate / targetRate;
  for (let index = 0; index < outputLength; index += 1) {
    const sourcePosition = index * rateRatio;
    const leftIndex = Math.floor(sourcePosition);
    const rightIndex = Math.min(leftIndex + 1, pcm.length - 1);
    const fraction = sourcePosition - leftIndex;
    const sample =
      pcm[leftIndex] + (pcm[rightIndex] - pcm[leftIndex]) * fraction;
    output[index] = sample / 0x8000;
  }
  return output;
};

const toInt16Sample = value => {
  const sample = Math.max(-1, Math.min(1, value));
  return sample < 0 ? sample * 0x8000 : sample * 0x7fff;
};

const createInputResampler = () => {
  let bufferedSamples = new Float32Array(0);
  let nextSourcePosition = 0;
  let sourceSampleRate;

  const reset = () => {
    bufferedSamples = new Float32Array(0);
    nextSourcePosition = 0;
    sourceSampleRate = undefined;
  };

  const process = (samples, inputRate) => {
    if (!samples.length || !Number.isFinite(inputRate) || inputRate <= 0) {
      return new Int16Array(0);
    }
    if (sourceSampleRate !== inputRate) {
      reset();
      sourceSampleRate = inputRate;
    }

    const combined = new Float32Array(bufferedSamples.length + samples.length);
    combined.set(bufferedSamples);
    combined.set(samples, bufferedSamples.length);
    bufferedSamples = combined;

    const ratio = inputRate / INPUT_SAMPLE_RATE;
    const output = [];
    while (nextSourcePosition < bufferedSamples.length) {
      const leftIndex = Math.floor(nextSourcePosition);
      const fraction = nextSourcePosition - leftIndex;
      if (fraction > 0 && leftIndex + 1 >= bufferedSamples.length) break;
      const rightIndex = Math.min(leftIndex + 1, bufferedSamples.length - 1);
      const sample =
        bufferedSamples[leftIndex] +
        (bufferedSamples[rightIndex] - bufferedSamples[leftIndex]) * fraction;
      output.push(toInt16Sample(sample));
      nextSourcePosition += ratio;
    }

    const consumedSamples = Math.min(
      Math.floor(nextSourcePosition),
      bufferedSamples.length
    );
    bufferedSamples = bufferedSamples.slice(consumedSamples);
    nextSourcePosition -= consumedSamples;
    return Int16Array.from(output);
  };

  return { process, reset };
};

const websocketUrl = path => {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${protocol}//${window.location.host}${path}`;
};

export function useVoiceAgentPreview(assistantId) {
  const status = ref('idle');
  const errorCode = ref('');
  const inputLevel = ref(0);
  const outputLevel = ref(0);
  const elapsedSeconds = ref(0);
  const provider = ref('');
  const isMuted = ref(false);
  const outputSampleRate = ref(DEFAULT_OUTPUT_SAMPLE_RATE);

  let audioContext;
  let mediaStream;
  let sourceNode;
  let processorNode;
  let outputProcessorNode;
  let silentGain;
  let socket;
  let timer;
  let readyTimeout;
  let workletsReady = false;
  let pendingInput = [];
  let nextPlaybackTime = 0;
  let activeAttempt = 0;
  const inputResampler = createInputResampler();
  const activeOutputSources = new Set();

  const isActive = computed(() =>
    ['connecting', 'listening', 'speaking'].includes(status.value)
  );
  const isConnected = computed(() =>
    ['listening', 'speaking'].includes(status.value)
  );

  const setOutputState = level => {
    outputLevel.value = level;
    status.value = activeOutputSources.size > 0 ? 'speaking' : 'listening';
  };

  const clearOutput = () => {
    outputProcessorNode?.port.postMessage({ type: 'clear' });
    activeOutputSources.forEach(output => {
      output.stop();
      output.disconnect();
    });
    activeOutputSources.clear();
    nextPlaybackTime = audioContext?.currentTime || 0;
    if (isActive.value) setOutputState(0);
  };

  const playOutput = encoded => {
    if (!audioContext) return;
    const expectedByteLength =
      (outputSampleRate.value *
        OUTPUT_FRAME_DURATION_MS *
        PCM_BYTES_PER_SAMPLE) /
      1000;
    const pcm = base64ToInt16(encoded, expectedByteLength);
    let peak = 0;
    for (let index = 0; index < pcm.length; index += 1) {
      peak = Math.max(peak, Math.abs(pcm[index] / 0x8000));
    }
    outputLevel.value = peak;

    if (outputProcessorNode) {
      const samples = resampleForOutput(
        pcm,
        outputSampleRate.value,
        audioContext.sampleRate
      );
      outputProcessorNode.port.postMessage({ type: 'audio', samples }, [
        samples.buffer,
      ]);
      return;
    }

    status.value = 'speaking';
    const buffer = audioContext.createBuffer(
      1,
      pcm.length,
      outputSampleRate.value
    );
    const channel = buffer.getChannelData(0);
    for (let index = 0; index < pcm.length; index += 1) {
      channel[index] = pcm[index] / 0x8000;
    }
    const output = audioContext.createBufferSource();
    output.buffer = buffer;
    output.connect(audioContext.destination);
    const startsAt = Math.max(
      audioContext.currentTime + 0.01,
      nextPlaybackTime
    );
    nextPlaybackTime = startsAt + buffer.duration;
    activeOutputSources.add(output);
    setOutputState(peak);
    output.onended = () => {
      activeOutputSources.delete(output);
      if (!activeOutputSources.size && isActive.value) setOutputState(0);
      output.disconnect();
    };
    output.start(startsAt);
  };

  const prepareAudioWorklets = async (activeAudioContext, attempt) => {
    if (!activeAudioContext.audioWorklet || !window.AudioWorkletNode) return;
    let setupTimeout;
    try {
      await Promise.race([
        Promise.all([
          activeAudioContext.audioWorklet.addModule(
            new URL('./voicePreviewInputProcessor.js', import.meta.url)
          ),
          activeAudioContext.audioWorklet.addModule(
            new URL('./voicePreviewOutputProcessor.js', import.meta.url)
          ),
        ]),
        new Promise((_, reject) => {
          setupTimeout = window.setTimeout(
            () => reject(new Error('audio_worklet_timeout')),
            AUDIO_WORKLET_TIMEOUT_MS
          );
        }),
      ]);
      if (
        audioContext !== activeAudioContext ||
        activeAttempt !== attempt ||
        !isActive.value
      )
        return;
      outputProcessorNode = new window.AudioWorkletNode(
        activeAudioContext,
        'voice-preview-output'
      );
      outputProcessorNode.port.onmessage = event => {
        if (activeAttempt !== attempt || !isActive.value) return;
        if (event.data?.type === 'playing') {
          status.value = 'speaking';
        } else if (event.data?.type === 'idle') {
          outputLevel.value = 0;
          status.value = 'listening';
        }
      };
      outputProcessorNode.connect(activeAudioContext.destination);
      workletsReady = true;
    } catch {
      if (audioContext === activeAudioContext && activeAttempt === attempt) {
        outputProcessorNode = undefined;
        workletsReady = false;
      }
    } finally {
      window.clearTimeout(setupTimeout);
    }
  };

  const sendInputFrames = samples => {
    pendingInput.push(...samples);
    while (pendingInput.length >= INPUT_FRAME_SAMPLES) {
      const frame = new Int16Array(pendingInput.splice(0, INPUT_FRAME_SAMPLES));
      if (
        socket?.readyState === WebSocket.OPEN &&
        status.value !== 'connecting'
      ) {
        socket.send(
          JSON.stringify({
            type: 'AUDIO_IN',
            data: bytesToBase64(new Uint8Array(frame.buffer)),
            mime_type: 'audio/pcm;rate=16000',
          })
        );
      }
    }
  };

  const processInput = (samples, sampleRate) => {
    if (!isActive.value) return;
    let sum = 0;
    samples.forEach(sample => {
      sum += sample * sample;
    });
    inputLevel.value = Math.min(1, Math.sqrt(sum / samples.length) * 4);
    sendInputFrames(inputResampler.process(samples, sampleRate));
  };

  const startCapture = async attempt => {
    const activeAudioContext = audioContext;
    const captureSampleRate = activeAudioContext.sampleRate;
    sourceNode = activeAudioContext.createMediaStreamSource(mediaStream);
    silentGain = audioContext.createGain();
    silentGain.gain.value = 0;

    if (workletsReady) {
      if (
        audioContext !== activeAudioContext ||
        activeAttempt !== attempt ||
        !isConnected.value
      )
        return false;
      processorNode = new window.AudioWorkletNode(
        activeAudioContext,
        'voice-preview-input',
        {
          numberOfInputs: 1,
          numberOfOutputs: 1,
          outputChannelCount: [1],
          channelCount: 1,
          channelCountMode: 'explicit',
        }
      );
      processorNode.port.onmessage = event =>
        processInput(event.data, captureSampleRate);
    } else {
      processorNode = activeAudioContext.createScriptProcessor(2048, 1, 1);
      processorNode.onaudioprocess = event =>
        processInput(event.inputBuffer.getChannelData(0), captureSampleRate);
    }
    sourceNode.connect(processorNode);
    processorNode.connect(silentGain);
    silentGain.connect(activeAudioContext.destination);
    return true;
  };

  const stop = async ({ failed = false, attempt = activeAttempt } = {}) => {
    if (attempt !== activeAttempt) return;
    activeAttempt += 1;
    window.clearInterval(timer);
    window.clearTimeout(readyTimeout);
    timer = undefined;
    readyTimeout = undefined;
    if (!failed) status.value = 'idle';
    const activeSocket = socket;
    socket = undefined;
    if (activeSocket && activeSocket.readyState < WebSocket.CLOSING) {
      activeSocket.onclose = null;
      activeSocket.close(1000, 'preview_stopped');
    }
    if (processorNode?.port) processorNode.port.onmessage = null;
    if (outputProcessorNode?.port) outputProcessorNode.port.onmessage = null;
    if (processorNode) processorNode.onaudioprocess = null;
    processorNode?.disconnect();
    outputProcessorNode?.disconnect();
    sourceNode?.disconnect();
    silentGain?.disconnect();
    processorNode = undefined;
    outputProcessorNode = undefined;
    workletsReady = false;
    sourceNode = undefined;
    silentGain = undefined;
    mediaStream?.getTracks().forEach(track => track.stop());
    mediaStream = undefined;
    clearOutput();
    const activeAudioContext = audioContext;
    audioContext = undefined;
    pendingInput = [];
    inputResampler.reset();
    nextPlaybackTime = 0;

    inputLevel.value = 0;
    outputLevel.value = 0;
    outputSampleRate.value = DEFAULT_OUTPUT_SAMPLE_RATE;
    provider.value = '';
    isMuted.value = false;
    if (activeAudioContext && activeAudioContext.state !== 'closed')
      await activeAudioContext.close();
  };

  const toggleMute = () => {
    if (!mediaStream) return;
    isMuted.value = !isMuted.value;
    mediaStream.getAudioTracks().forEach(track => {
      track.enabled = !isMuted.value;
    });
    if (isMuted.value) inputLevel.value = 0;
  };

  const fail = async (code, attempt = activeAttempt) => {
    if (attempt !== activeAttempt) return;
    errorCode.value = code;
    status.value = 'error';
    await stop({ failed: true, attempt });
  };

  const start = async () => {
    if (isActive.value) return;
    const attempt = activeAttempt + 1;
    activeAttempt = attempt;
    errorCode.value = '';
    elapsedSeconds.value = 0;
    provider.value = '';
    outputSampleRate.value = DEFAULT_OUTPUT_SAMPLE_RATE;
    status.value = 'connecting';
    try {
      const AudioContextConstructor =
        window.AudioContext || window.webkitAudioContext;
      if (!AudioContextConstructor)
        throw new Error('audio_context_unavailable');
      audioContext = new AudioContextConstructor({
        latencyHint: 'interactive',
      });
      const audioContextResume = audioContext.resume();
      const audioWorkletSetup = prepareAudioWorklets(audioContext, attempt);
      const requestedStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });
      if (attempt !== activeAttempt) {
        requestedStream.getTracks().forEach(track => track.stop());
        return;
      }
      mediaStream = requestedStream;
      await Promise.all([audioContextResume, audioWorkletSetup]);
      if (attempt !== activeAttempt) return;
      if (audioContext.state !== 'running')
        throw new Error('audio_context_suspended');
      const { data } = await CaptainAssistantAPI.voicePreview(
        assistantId.value
      );
      if (attempt !== activeAttempt) return;
      if (
        typeof data?.token !== 'string' ||
        !data.token ||
        typeof data.websocket_path !== 'string' ||
        !data.websocket_path.startsWith('/')
      ) {
        throw new Error('invalid_preview_capability');
      }
      socket = new WebSocket(websocketUrl(data.websocket_path));
      readyTimeout = window.setTimeout(() => {
        if (status.value === 'connecting') fail('connection', attempt);
      }, READY_TIMEOUT_MS);
      socket.onopen = () => {
        if (attempt !== activeAttempt) return;
        socket.send(JSON.stringify({ type: 'AUTH', token: data.token }));
      };
      socket.onmessage = async event => {
        if (attempt !== activeAttempt) return;
        let message;
        try {
          message = JSON.parse(event.data);
        } catch {
          await fail('protocol', attempt);
          return;
        }
        if (message.type === 'READY') {
          const sampleRate = Number(message.sample_rate);
          if (
            status.value !== 'connecting' ||
            typeof message.provider !== 'string' ||
            !message.provider ||
            !Number.isInteger(sampleRate) ||
            sampleRate < 8000 ||
            sampleRate > 48000
          ) {
            await fail('protocol', attempt);
            return;
          }
          window.clearTimeout(readyTimeout);
          readyTimeout = undefined;
          provider.value = message.provider;
          outputSampleRate.value = sampleRate;
          status.value = 'listening';
          try {
            if (!(await startCapture(attempt))) return;
          } catch {
            await fail('unavailable', attempt);
            return;
          }
          timer = window.setInterval(() => {
            elapsedSeconds.value += 1;
          }, 1000);
        } else if (message.type === 'AUDIO_OUT') {
          if (!isConnected.value) {
            await fail('protocol', attempt);
            return;
          }
          if (
            message.mime_type !== `audio/pcm;rate=${outputSampleRate.value}`
          ) {
            await fail('protocol', attempt);
            return;
          }
          try {
            playOutput(message.data);
          } catch {
            await fail('protocol', attempt);
          }
        } else if (message.type === 'CLEAR_AUDIO') {
          if (!isConnected.value) {
            await fail('protocol', attempt);
            return;
          }
          clearOutput();
        } else if (message.type === 'ERROR') {
          const runtimeErrors = {
            preview_capacity_exhausted: 'capacity',
            origin_forbidden: 'origin',
          };
          await fail(runtimeErrors[message.code] || 'unavailable', attempt);
        } else {
          await fail('protocol', attempt);
        }
      };
      socket.onerror = () => {
        if (attempt !== activeAttempt) return;
        errorCode.value = 'connection';
      };
      socket.onclose = async event => {
        if (attempt !== activeAttempt) return;
        if (status.value !== 'idle') {
          const failed = event.code !== 1000;
          if (failed) {
            status.value = 'error';
            const closeErrors = {
              4401: 'expired',
              4403: 'origin',
              4429: 'capacity',
            };
            errorCode.value ||= closeErrors[event.code] || 'connection';
          }
          await stop({ failed, attempt });
        }
      };
    } catch (error) {
      if (attempt !== activeAttempt) return;
      const apiError = error?.response?.data?.error;
      if (error?.name === 'NotAllowedError') errorCode.value = 'microphone';
      else if (apiError === 'preview_capacity_exhausted')
        errorCode.value = 'capacity';
      else errorCode.value = 'unavailable';
      status.value = 'error';
      await stop({ failed: true, attempt });
    }
  };

  onBeforeUnmount(() => stop());

  return {
    elapsedSeconds,
    errorCode,
    inputLevel,
    isActive,
    isConnected,
    isMuted,
    outputLevel,
    provider,
    start,
    status,
    stop,
    toggleMute,
  };
}
