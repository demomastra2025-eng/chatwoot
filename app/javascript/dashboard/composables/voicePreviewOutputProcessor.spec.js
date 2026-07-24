/* eslint-disable max-classes-per-file */
let OutputProcessor;

class FakeAudioWorkletProcessor {
  constructor() {
    this.port = { onmessage: null, postMessage: vi.fn() };
  }
}

describe('voicePreviewOutputProcessor', () => {
  beforeAll(async () => {
    vi.stubGlobal('sampleRate', 48000);
    vi.stubGlobal('AudioWorkletProcessor', FakeAudioWorkletProcessor);
    vi.stubGlobal('registerProcessor', (_name, processor) => {
      OutputProcessor = processor;
    });
    await import('./voicePreviewOutputProcessor.js');
  });

  it('prebuffers and renders queued audio without gaps', () => {
    const processor = new OutputProcessor();
    const samples = Float32Array.from({ length: 4800 }, (_, index) =>
      Math.sin((2 * Math.PI * 440 * index) / 48000)
    );
    processor.port.onmessage({ data: { type: 'audio', samples } });
    const output = new Float32Array(128);

    expect(processor.process([], [[output]])).toBe(true);
    expect(output.some(sample => Math.abs(sample) > 0.1)).toBe(true);
    expect(processor.port.postMessage).toHaveBeenCalledWith({
      type: 'playing',
    });
    expect(processor.bufferedSamples).toBe(4672);
  });

  it('waits for a jitter-resistant buffer before playback', () => {
    const processor = new OutputProcessor();
    processor.port.onmessage({
      data: { type: 'audio', samples: new Float32Array(4799).fill(0.5) },
    });
    const output = new Float32Array(128);

    processor.process([], [[output]]);

    expect(output.every(sample => sample === 0)).toBe(true);
    expect(processor.port.postMessage).not.toHaveBeenCalled();

    processor.port.onmessage({
      data: { type: 'audio', samples: new Float32Array([0.5]) },
    });
    processor.process([], [[output]]);

    expect(output.some(sample => sample === 0.5)).toBe(true);
    expect(processor.port.postMessage).toHaveBeenCalledWith({
      type: 'playing',
    });
  });

  it('clears buffered audio immediately on interruption', () => {
    const processor = new OutputProcessor();
    processor.port.onmessage({
      data: { type: 'audio', samples: new Float32Array(4800) },
    });
    processor.process([], [[new Float32Array(128)]]);

    processor.port.onmessage({ data: { type: 'clear' } });

    expect(processor.bufferedSamples).toBe(0);
    expect(processor.queue).toHaveLength(0);
    expect(processor.port.postMessage).toHaveBeenLastCalledWith({
      type: 'idle',
    });
  });
});
