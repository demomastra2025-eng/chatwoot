let InputProcessor;

class FakeAudioWorkletProcessor {
  constructor() {
    this.port = { postMessage: vi.fn() };
  }
}

describe('voicePreviewInputProcessor', () => {
  beforeAll(async () => {
    vi.stubGlobal('AudioWorkletProcessor', FakeAudioWorkletProcessor);
    vi.stubGlobal(
      'registerProcessor',
      vi.fn((_name, processorClass) => {
        InputProcessor = processorClass;
      })
    );
    await import('./voicePreviewInputProcessor');
  });

  afterAll(() => {
    vi.unstubAllGlobals();
  });

  it('keeps the input graph active and forwards captured samples', () => {
    const processor = new InputProcessor();
    const input = Float32Array.from([0.25, -0.5, 0.75]);
    const output = new Float32Array(input.length);

    expect(processor.process([[input]], [[output]])).toBe(true);
    expect(Array.from(output)).toEqual(Array.from(input));
    expect(processor.port.postMessage).toHaveBeenCalledOnce();
    expect(processor.port.postMessage.mock.calls[0][0]).not.toBe(input);
    expect(Array.from(processor.port.postMessage.mock.calls[0][0])).toEqual(
      Array.from(input)
    );
    expect(processor.port.postMessage.mock.calls[0][1]).toEqual([
      processor.port.postMessage.mock.calls[0][0].buffer,
    ]);
  });

  it('stays alive when the browser has no input channel yet', () => {
    const processor = new InputProcessor();

    expect(processor.process([[]], [[new Float32Array(3)]])).toBe(true);
    expect(processor.port.postMessage).not.toHaveBeenCalled();
  });
});
