import { beforeEach, describe, expect, it, vi } from 'vitest';
import JanusAiMediaBridge from './janusAiMediaBridge';

const pcm16Base64 = samples => {
  const bytes = new Uint8Array(samples.length * 2);
  const view = new DataView(bytes.buffer);
  samples.forEach((sample, index) => view.setInt16(index * 2, sample, true));
  let binary = '';
  bytes.forEach(byte => {
    binary += String.fromCharCode(byte);
  });
  return window.btoa(binary);
};

function createAudioContextMock({
  sampleRate = 16000,
  currentTime = 0,
  state = 'running',
} = {}) {
  const createdBuffers = [];
  const createdSources = [];
  const createdProcessors = [];
  const createdGains = [];
  const resumeMock = vi.fn(function resume() {
    this.state = 'running';
    return Promise.resolve();
  });
  const destination = {
    stream: {
      getAudioTracks: () => [{ id: 'ai-output-track', kind: 'audio' }],
      getTracks: () => [{ stop: vi.fn() }],
    },
  };

  function AudioContextMock() {
    this.sampleRate = sampleRate;
    this.currentTime = currentTime;
    this.state = state;
    this.destination = {};
  }

  AudioContextMock.prototype.createMediaStreamDestination = () => destination;

  AudioContextMock.prototype.createBuffer = (_channels, length, rate) => {
    const buffer = {
      length,
      sampleRate: rate,
      duration: length / rate,
      copyToChannel: vi.fn(),
    };
    createdBuffers.push(buffer);
    return buffer;
  };

  AudioContextMock.prototype.createBufferSource = () => {
    const source = {
      connect: vi.fn(),
      start: vi.fn(),
      stop: vi.fn(),
    };
    createdSources.push(source);
    return source;
  };

  AudioContextMock.prototype.createMediaStreamSource = () => ({
    connect: vi.fn(),
    disconnect: vi.fn(),
  });

  AudioContextMock.prototype.createScriptProcessor = (...args) => {
    const processor = {
      args,
      connect: vi.fn(),
      disconnect: vi.fn(),
      onaudioprocess: null,
    };
    createdProcessors.push(processor);
    return processor;
  };

  AudioContextMock.prototype.createGain = () => {
    const gain = {
      gain: { value: 1 },
      connect: vi.fn(),
      disconnect: vi.fn(),
    };
    createdGains.push(gain);
    return gain;
  };

  AudioContextMock.prototype.resume = resumeMock;
  AudioContextMock.prototype.close = () => Promise.resolve();

  return {
    AudioContextMock,
    createdBuffers,
    createdSources,
    createdProcessors,
    createdGains,
    resumeMock,
  };
}

function WebSocketMock() {}
WebSocketMock.OPEN = 1;

describe('JanusAiMediaBridge', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('uses AUDIO_OUT mime sample rate instead of assuming 8 kHz', () => {
    const { AudioContextMock, createdBuffers } = createAudioContextMock({
      sampleRate: 16000,
    });
    const bridge = new JanusAiMediaBridge({
      streamUrl: 'ws://127.0.0.1/ai',
      AudioContextImpl: AudioContextMock,
      WebSocketImpl: WebSocketMock,
    });

    bridge.handleMessage(
      JSON.stringify({
        type: 'AUDIO_OUT',
        data: pcm16Base64([100, 200]),
        mime_type: 'audio/pcm;rate=16000',
      })
    );

    expect(createdBuffers[0].length).toBe(2);
    expect(createdBuffers[0].sampleRate).toBe(16000);
  });

  it('drops queued AI audio when browser playback falls behind', () => {
    const { AudioContextMock, createdSources } = createAudioContextMock({
      sampleRate: 16000,
      currentTime: 1,
    });
    const bridge = new JanusAiMediaBridge({
      streamUrl: 'ws://127.0.0.1/ai',
      AudioContextImpl: AudioContextMock,
      WebSocketImpl: WebSocketMock,
    });
    const staleSource = { stop: vi.fn() };
    bridge.outputSources.add(staleSource);
    bridge.outputCursor = 2;

    bridge.handleMessage(
      JSON.stringify({
        type: 'AUDIO_OUT',
        data: pcm16Base64([100, 200]),
        mime_type: 'audio/pcm;rate=16000',
      })
    );

    expect(staleSource.stop).toHaveBeenCalled();
    expect(createdSources.at(-1).start).toHaveBeenCalledWith(1.04);
  });

  it('mixes remote input channels and applies input gain before streaming to AI runtime', () => {
    const { AudioContextMock, createdProcessors, createdGains } =
      createAudioContextMock({
        sampleRate: 16000,
      });
    const sent = [];
    const bridge = new JanusAiMediaBridge({
      streamUrl: 'ws://127.0.0.1/ai',
      AudioContextImpl: AudioContextMock,
      WebSocketImpl: WebSocketMock,
    });
    bridge.ws = {
      readyState: WebSocketMock.OPEN,
      send: frame => sent.push(JSON.parse(frame)),
    };

    bridge.attachRemoteStream({});
    expect(createdProcessors[0].args).toEqual([1024, 2, 1]);
    expect(createdGains[0].gain.value).toBeGreaterThan(0);
    expect(createdGains[0].gain.value).toBeLessThan(0.001);
    createdProcessors[0].onaudioprocess({
      inputBuffer: {
        length: 2,
        numberOfChannels: 2,
        getChannelData: channel =>
          channel === 0
            ? new Float32Array([0, 0])
            : new Float32Array([0.25, -0.25]),
      },
    });

    const bytes = Uint8Array.from(window.atob(sent[0].data), char =>
      char.charCodeAt(0)
    );
    const view = new DataView(bytes.buffer);

    expect(sent[0].type).toBe('AUDIO_IN');
    expect(sent[0].mime_type).toBe('audio/pcm;rate=16000');
    expect(view.getInt16(0, true)).toBeGreaterThan(10000);
    expect(view.getInt16(2, true)).toBeLessThan(-10000);
  });

  it('resumes the browser audio graph when remote caller stream is attached', async () => {
    const { AudioContextMock, resumeMock } = createAudioContextMock({
      state: 'suspended',
    });
    const bridge = new JanusAiMediaBridge({
      streamUrl: 'ws://127.0.0.1/ai',
      AudioContextImpl: AudioContextMock,
      WebSocketImpl: WebSocketMock,
    });

    bridge.attachRemoteStream({});
    await Promise.resolve();

    expect(resumeMock).toHaveBeenCalled();
    expect(bridge.audioContext.state).toBe('running');
  });
});
