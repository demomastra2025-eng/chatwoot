/* eslint-disable max-classes-per-file, class-methods-use-this */
import { defineComponent, ref } from 'vue';
import { mount } from '@vue/test-utils';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import { useVoiceAgentPreview } from './useVoiceAgentPreview';

vi.mock('dashboard/api/captain/assistant', () => ({
  default: { voicePreview: vi.fn() },
}));

class FakeWebSocket {
  static OPEN = 1;

  static CLOSING = 2;

  static instances = [];

  constructor(url) {
    this.url = url;
    this.readyState = FakeWebSocket.OPEN;
    this.send = vi.fn();
    this.close = vi.fn(() => {
      this.readyState = 3;
    });
    FakeWebSocket.instances.push(this);
  }
}

class FakeAudioContext {
  static sources = [];

  static lastInstance;

  static hasAudioWorklet = false;

  static audioWorkletFailure = false;

  static sampleRate = 48000;

  constructor() {
    FakeAudioContext.lastInstance = this;
    this.currentTime = 0;
    this.destination = {};
    this.sampleRate = FakeAudioContext.sampleRate;
    this.state = 'running';
    if (FakeAudioContext.hasAudioWorklet) {
      this.audioWorklet = {
        addModule: vi.fn(async () => {
          if (FakeAudioContext.audioWorkletFailure) throw new Error('blocked');
        }),
      };
    }
    this.close = vi.fn(async () => {
      this.state = 'closed';
    });
    this.resume = vi.fn(async () => {});
  }

  createMediaStreamSource() {
    return { connect: vi.fn(), disconnect: vi.fn() };
  }

  createScriptProcessor() {
    this.processor = { connect: vi.fn(), disconnect: vi.fn() };
    return this.processor;
  }

  createGain() {
    return { gain: { value: 1 }, connect: vi.fn(), disconnect: vi.fn() };
  }

  createBuffer(_channels, length, sampleRate) {
    return {
      duration: length / sampleRate,
      getChannelData: () => new Float32Array(length),
    };
  }

  createBufferSource() {
    const source = {
      connect: vi.fn(),
      disconnect: vi.fn(),
      start: vi.fn(),
      stop: vi.fn(),
      onended: undefined,
    };
    FakeAudioContext.sources.push(source);
    return source;
  }
}

class FakeAudioWorkletNode {
  static instances = [];

  constructor(_context, name, options) {
    this.name = name;
    this.options = options;
    this.port = { onmessage: null, postMessage: vi.fn() };
    this.connect = vi.fn();
    this.disconnect = vi.fn();
    FakeAudioWorkletNode.instances.push(this);
  }
}

describe('useVoiceAgentPreview', () => {
  let preview;
  let stream;

  beforeEach(() => {
    FakeWebSocket.instances = [];
    FakeAudioContext.sources = [];
    FakeAudioContext.lastInstance = undefined;
    FakeAudioContext.hasAudioWorklet = false;
    FakeAudioContext.audioWorkletFailure = false;
    FakeAudioContext.sampleRate = 48000;
    FakeAudioWorkletNode.instances = [];
    global.WebSocket = FakeWebSocket;
    global.AudioContext = FakeAudioContext;
    delete global.AudioWorkletNode;
    const audioTrack = { enabled: true, stop: vi.fn() };
    stream = {
      getTracks: () => [audioTrack],
      getAudioTracks: () => [audioTrack],
    };
    Object.defineProperty(global.navigator, 'mediaDevices', {
      configurable: true,
      value: {
        getUserMedia: vi.fn(async () => {
          expect(FakeAudioContext.lastInstance.resume).toHaveBeenCalledOnce();
          return stream;
        }),
      },
    });
    CaptainAssistantAPI.voicePreview.mockResolvedValue({
      data: {
        websocket_path: '/voice-preview/ws',
        token: 'preview-token',
      },
    });
  });

  it('bridges microphone/audio and clears scheduled output on interruption', async () => {
    const wrapper = mount(
      defineComponent({
        setup() {
          preview = useVoiceAgentPreview(ref(42));
          return () => null;
        },
      })
    );

    await preview.start();
    const socket = FakeWebSocket.instances[0];
    expect(socket.url).toBe('ws://localhost:3000/voice-preview/ws');

    socket.onopen();
    expect(JSON.parse(socket.send.mock.calls[0][0])).toEqual({
      type: 'AUTH',
      token: 'preview-token',
    });

    socket.onmessage({
      data: JSON.stringify({
        type: 'READY',
        provider: 'cartesia',
        sample_rate: 8000,
      }),
    });
    expect(preview.status.value).toBe('listening');
    expect(preview.isConnected.value).toBe(true);
    expect(preview.provider.value).toBe('cartesia');

    preview.toggleMute();
    expect(preview.isMuted.value).toBe(true);
    expect(stream.getAudioTracks()[0].enabled).toBe(false);
    preview.toggleMute();
    expect(stream.getAudioTracks()[0].enabled).toBe(true);

    const context = FakeAudioContext.sources;
    const pcm = window.btoa(String.fromCharCode(...new Uint8Array(320)));
    socket.onmessage({
      data: JSON.stringify({ type: 'AUDIO_OUT', data: pcm }),
    });
    expect(context[0].start).toHaveBeenCalledOnce();
    expect(preview.status.value).toBe('speaking');

    socket.onmessage({ data: JSON.stringify({ type: 'CLEAR_AUDIO' }) });
    expect(context[0].stop).toHaveBeenCalledOnce();
    expect(preview.status.value).toBe('listening');

    const processor = FakeAudioContext.lastInstance.processor;
    await preview.stop();
    expect(socket.close).toHaveBeenCalledWith(1000, 'preview_stopped');
    expect(processor.onaudioprocess).toBeNull();
    expect(preview.status.value).toBe('idle');
    wrapper.unmount();
  });

  it('maps runtime close reasons to actionable errors', async () => {
    mount(
      defineComponent({
        setup() {
          preview = useVoiceAgentPreview(ref(42));
          return () => null;
        },
      })
    );

    await preview.start();
    const socket = FakeWebSocket.instances[0];
    await socket.onclose({ code: 4429 });

    expect(preview.status.value).toBe('error');
    expect(preview.errorCode.value).toBe('capacity');
  });

  it('queues resampled output through a stable AudioWorklet', async () => {
    FakeAudioContext.hasAudioWorklet = true;
    global.AudioWorkletNode = FakeAudioWorkletNode;
    mount(
      defineComponent({
        setup() {
          preview = useVoiceAgentPreview(ref(42));
          return () => null;
        },
      })
    );

    await preview.start();
    const socket = FakeWebSocket.instances[0];
    await socket.onmessage({
      data: JSON.stringify({
        type: 'READY',
        provider: 'gemini-live',
        sample_rate: 8000,
      }),
    });
    const outputNode = FakeAudioWorkletNode.instances.find(
      node => node.name === 'voice-preview-output'
    );
    const inputNode = FakeAudioWorkletNode.instances.find(
      node => node.name === 'voice-preview-input'
    );
    const pcm = window.btoa(String.fromCharCode(...new Uint8Array(320)));
    await socket.onmessage({
      data: JSON.stringify({ type: 'AUDIO_OUT', data: pcm }),
    });

    expect(outputNode.port.postMessage).toHaveBeenCalledOnce();
    expect(preview.status.value).toBe('listening');
    outputNode.port.onmessage({ data: { type: 'playing' } });
    expect(preview.status.value).toBe('speaking');
    outputNode.port.onmessage({ data: { type: 'idle' } });
    expect(preview.status.value).toBe('listening');
    expect(inputNode.options).toEqual({
      numberOfInputs: 1,
      numberOfOutputs: 1,
      outputChannelCount: [1],
      channelCount: 1,
      channelCountMode: 'explicit',
    });
    const [message, transfer] = outputNode.port.postMessage.mock.calls[0];
    expect(message.type).toBe('audio');
    expect(message.samples).toBeInstanceOf(Float32Array);
    expect(message.samples).toHaveLength(960);
    expect(transfer).toEqual([message.samples.buffer]);
  });

  it.each([
    [48000, 375],
    [44100, 345],
  ])(
    'preserves the 16 kHz input duration across %i Hz worklet chunks',
    async (sampleRate, chunkCount) => {
      FakeAudioContext.hasAudioWorklet = true;
      FakeAudioContext.sampleRate = sampleRate;
      global.AudioWorkletNode = FakeAudioWorkletNode;
      mount(
        defineComponent({
          setup() {
            preview = useVoiceAgentPreview(ref(42));
            return () => null;
          },
        })
      );

      await preview.start();
      const socket = FakeWebSocket.instances[0];
      await socket.onmessage({
        data: JSON.stringify({
          type: 'READY',
          provider: 'gemini-live',
          sample_rate: 8000,
        }),
      });
      const inputNode = FakeAudioWorkletNode.instances.find(
        node => node.name === 'voice-preview-input'
      );

      for (let index = 0; index < chunkCount; index += 1) {
        inputNode.port.onmessage({ data: new Float32Array(128) });
      }

      const audioFrames = socket.send.mock.calls
        .map(([payload]) => JSON.parse(payload))
        .filter(payload => payload.type === 'AUDIO_IN');
      expect(audioFrames).toHaveLength(50);
    }
  );

  it('falls back to scheduled buffers when AudioWorklet loading fails', async () => {
    FakeAudioContext.hasAudioWorklet = true;
    FakeAudioContext.audioWorkletFailure = true;
    global.AudioWorkletNode = FakeAudioWorkletNode;
    mount(
      defineComponent({
        setup() {
          preview = useVoiceAgentPreview(ref(42));
          return () => null;
        },
      })
    );

    await preview.start();
    const socket = FakeWebSocket.instances[0];
    await socket.onmessage({
      data: JSON.stringify({
        type: 'READY',
        provider: 'gemini-live',
        sample_rate: 8000,
      }),
    });
    const pcm = window.btoa(String.fromCharCode(...new Uint8Array(320)));
    await socket.onmessage({
      data: JSON.stringify({ type: 'AUDIO_OUT', data: pcm }),
    });

    expect(FakeAudioWorkletNode.instances).toHaveLength(0);
    expect(FakeAudioContext.sources[0].start).toHaveBeenCalledOnce();
    expect(preview.status.value).toBe('speaking');
  });

  it('rejects malformed runtime audio and closes the session cleanly', async () => {
    mount(
      defineComponent({
        setup() {
          preview = useVoiceAgentPreview(ref(42));
          return () => null;
        },
      })
    );

    await preview.start();
    const socket = FakeWebSocket.instances[0];
    await socket.onmessage({
      data: JSON.stringify({
        type: 'READY',
        provider: 'gemini-live',
        sample_rate: 8000,
      }),
    });
    await socket.onmessage({
      data: JSON.stringify({ type: 'AUDIO_OUT', data: '%' }),
    });

    expect(preview.status.value).toBe('error');
    expect(preview.errorCode.value).toBe('protocol');
    expect(preview.isConnected.value).toBe(false);
    expect(socket.close).toHaveBeenCalledWith(1000, 'preview_stopped');
  });

  it('does not resurrect a session stopped while microphone access is pending', async () => {
    let resolveStream;
    navigator.mediaDevices.getUserMedia.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveStream = resolve;
        })
    );
    mount(
      defineComponent({
        setup() {
          preview = useVoiceAgentPreview(ref(42));
          return () => null;
        },
      })
    );

    const startPromise = preview.start();
    await Promise.resolve();
    await preview.stop();
    resolveStream(stream);
    await startPromise;

    expect(stream.getTracks()[0].stop).toHaveBeenCalledOnce();
    expect(FakeWebSocket.instances).toHaveLength(0);
    expect(preview.status.value).toBe('idle');
  });

  it('maps preview reservation capacity errors before opening a socket', async () => {
    CaptainAssistantAPI.voicePreview.mockRejectedValueOnce({
      response: { data: { error: 'preview_capacity_exhausted' } },
    });
    mount(
      defineComponent({
        setup() {
          preview = useVoiceAgentPreview(ref(42));
          return () => null;
        },
      })
    );

    await preview.start();

    expect(preview.status.value).toBe('error');
    expect(preview.errorCode.value).toBe('capacity');
    expect(FakeWebSocket.instances).toHaveLength(0);
  });

  it('does not let a closing context clobber an immediate restart', async () => {
    mount(
      defineComponent({
        setup() {
          preview = useVoiceAgentPreview(ref(42));
          return () => null;
        },
      })
    );
    await preview.start();
    const firstContext = FakeAudioContext.lastInstance;
    let finishClose;
    firstContext.close.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          finishClose = resolve;
        })
    );

    const stopPromise = preview.stop();
    await preview.start();
    const restartedSocket = FakeWebSocket.instances[1];
    finishClose();
    await stopPromise;
    await restartedSocket.onmessage({
      data: JSON.stringify({
        type: 'READY',
        provider: 'gemini-live',
        sample_rate: 8000,
      }),
    });

    expect(preview.status.value).toBe('listening');
    expect(FakeAudioContext.lastInstance.state).toBe('running');
  });
});
