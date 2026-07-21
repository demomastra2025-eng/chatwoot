import { computed, onBeforeUnmount, ref } from 'vue';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';

const INPUT_SAMPLE_RATE = 16000;
const INPUT_FRAME_SAMPLES = 320;
const OUTPUT_SAMPLE_RATE = 8000;

const bytesToBase64 = bytes => {
  let binary = '';
  bytes.forEach(byte => {
    binary += String.fromCharCode(byte);
  });
  return window.btoa(binary);
};

const base64ToInt16 = value => {
  const binary = window.atob(value);
  const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
  return new Int16Array(bytes.buffer);
};

const resampleToInt16 = (samples, inputRate) => {
  const ratio = inputRate / INPUT_SAMPLE_RATE;
  const outputLength = Math.max(1, Math.floor(samples.length / ratio));
  const output = new Int16Array(outputLength);
  for (let index = 0; index < outputLength; index += 1) {
    const sourceIndex = Math.min(samples.length - 1, Math.floor(index * ratio));
    const sample = Math.max(-1, Math.min(1, samples[sourceIndex]));
    output[index] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
  }
  return output;
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

  let audioContext;
  let mediaStream;
  let sourceNode;
  let processorNode;
  let silentGain;
  let socket;
  let timer;
  let pendingInput = [];
  let nextPlaybackTime = 0;
  const activeOutputSources = new Set();

  const isActive = computed(() =>
    ['connecting', 'listening', 'speaking'].includes(status.value)
  );

  const setOutputState = level => {
    outputLevel.value = level;
    status.value = activeOutputSources.size > 0 ? 'speaking' : 'listening';
  };

  const clearOutput = () => {
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
    const pcm = base64ToInt16(encoded);
    const buffer = audioContext.createBuffer(1, pcm.length, OUTPUT_SAMPLE_RATE);
    const channel = buffer.getChannelData(0);
    let peak = 0;
    for (let index = 0; index < pcm.length; index += 1) {
      channel[index] = pcm[index] / 0x8000;
      peak = Math.max(peak, Math.abs(channel[index]));
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

  const startCapture = () => {
    sourceNode = audioContext.createMediaStreamSource(mediaStream);
    processorNode = audioContext.createScriptProcessor(2048, 1, 1);
    silentGain = audioContext.createGain();
    silentGain.gain.value = 0;
    processorNode.onaudioprocess = event => {
      const samples = event.inputBuffer.getChannelData(0);
      let sum = 0;
      samples.forEach(sample => {
        sum += sample * sample;
      });
      inputLevel.value = Math.min(1, Math.sqrt(sum / samples.length) * 4);
      sendInputFrames(resampleToInt16(samples, audioContext.sampleRate));
    };
    sourceNode.connect(processorNode);
    processorNode.connect(silentGain);
    silentGain.connect(audioContext.destination);
  };

  const stop = async ({ failed = false } = {}) => {
    window.clearInterval(timer);
    timer = undefined;
    if (!failed) status.value = 'idle';
    if (socket && socket.readyState < WebSocket.CLOSING)
      socket.close(1000, 'preview_stopped');
    socket = undefined;
    processorNode?.disconnect();
    sourceNode?.disconnect();
    silentGain?.disconnect();
    processorNode = undefined;
    sourceNode = undefined;
    silentGain = undefined;
    mediaStream?.getTracks().forEach(track => track.stop());
    mediaStream = undefined;
    clearOutput();
    if (audioContext && audioContext.state !== 'closed')
      await audioContext.close();
    audioContext = undefined;
    pendingInput = [];
    nextPlaybackTime = 0;

    inputLevel.value = 0;
    outputLevel.value = 0;
  };

  const start = async () => {
    if (isActive.value) return;
    errorCode.value = '';
    elapsedSeconds.value = 0;
    status.value = 'connecting';
    try {
      mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });
      audioContext = new AudioContext({ latencyHint: 'interactive' });
      await audioContext.resume();
      const { data } = await CaptainAssistantAPI.voicePreview(
        assistantId.value
      );
      socket = new WebSocket(websocketUrl(data.websocket_path));
      socket.onopen = () =>
        socket.send(JSON.stringify({ type: 'AUTH', token: data.token }));
      socket.onmessage = event => {
        const message = JSON.parse(event.data);
        if (message.type === 'READY') {
          provider.value = message.provider;
          status.value = 'listening';
          startCapture();
          timer = window.setInterval(() => {
            elapsedSeconds.value += 1;
          }, 1000);
        } else if (message.type === 'AUDIO_OUT') {
          playOutput(message.data);
        } else if (message.type === 'CLEAR_AUDIO') {
          clearOutput();
        }
      };
      socket.onerror = () => {
        errorCode.value = 'connection';
      };
      socket.onclose = async event => {
        if (status.value !== 'idle') {
          const failed = event.code !== 1000;
          if (failed) {
            status.value = 'error';
            errorCode.value ||= event.code === 4401 ? 'expired' : 'connection';
          }
          await stop({ failed });
        }
      };
    } catch (error) {
      errorCode.value =
        error?.name === 'NotAllowedError' ? 'microphone' : 'unavailable';
      status.value = 'error';
      await stop({ failed: true });
    }
  };

  onBeforeUnmount(() => stop());

  return {
    elapsedSeconds,
    errorCode,
    inputLevel,
    isActive,
    outputLevel,
    provider,
    start,
    status,
    stop,
  };
}
