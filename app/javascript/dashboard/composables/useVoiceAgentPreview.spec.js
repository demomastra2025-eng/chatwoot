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

  constructor() {
    this.currentTime = 0;
    this.destination = {};
    this.sampleRate = 48000;
    this.state = 'running';
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

describe('useVoiceAgentPreview', () => {
  let preview;
  let stream;

  beforeEach(() => {
    FakeWebSocket.instances = [];
    FakeAudioContext.sources = [];
    global.WebSocket = FakeWebSocket;
    global.AudioContext = FakeAudioContext;
    stream = { getTracks: () => [{ stop: vi.fn() }] };
    Object.defineProperty(global.navigator, 'mediaDevices', {
      configurable: true,
      value: { getUserMedia: vi.fn(async () => stream) },
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
      data: JSON.stringify({ type: 'READY', provider: 'cartesia' }),
    });
    expect(preview.status.value).toBe('listening');
    expect(preview.provider.value).toBe('cartesia');

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

    await preview.stop();
    expect(socket.close).toHaveBeenCalledWith(1000, 'preview_stopped');
    expect(preview.status.value).toBe('idle');
    wrapper.unmount();
  });
});
