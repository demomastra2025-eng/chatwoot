/* global sampleRate */
const PREBUFFER_SECONDS = 0.1;
const UNDERFLOW_GRACE_SECONDS = 0.05;
const RENDER_QUANTUM_SAMPLES = 128;

class VoicePreviewOutputProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.queue = [];
    this.queueOffset = 0;
    this.bufferedSamples = 0;
    this.isPlaying = false;
    this.emptyRenderCount = 0;
    this.startupRenderCount = 0;
    this.port.onmessage = event => {
      if (event.data?.type === 'clear') {
        this.clear();
        return;
      }
      if (event.data?.type !== 'audio' || !event.data.samples?.length) return;
      if (!this.isPlaying && this.bufferedSamples === 0) {
        this.startupRenderCount = 0;
      }
      this.queue.push(event.data.samples);
      this.bufferedSamples += event.data.samples.length;
      this.emptyRenderCount = 0;
    };
  }

  clear() {
    this.queue = [];
    this.queueOffset = 0;
    this.bufferedSamples = 0;
    this.emptyRenderCount = 0;
    this.startupRenderCount = 0;
    if (this.isPlaying) this.port.postMessage({ type: 'idle' });
    this.isPlaying = false;
  }

  process(_inputs, outputs) {
    const output = outputs[0]?.[0];
    if (!output) return true;
    output.fill(0);

    const prebufferSamples = sampleRate * PREBUFFER_SECONDS;
    if (!this.isPlaying && this.bufferedSamples > 0) {
      this.startupRenderCount += 1;
    }
    const startupRenderLimit = Math.ceil(
      prebufferSamples / RENDER_QUANTUM_SAMPLES
    );
    if (
      !this.isPlaying &&
      this.bufferedSamples < prebufferSamples &&
      this.startupRenderCount < startupRenderLimit
    )
      return true;
    if (!this.isPlaying && this.bufferedSamples > 0) {
      this.isPlaying = true;
      this.startupRenderCount = 0;
      this.port.postMessage({ type: 'playing' });
    }

    let outputOffset = 0;
    while (outputOffset < output.length && this.queue.length) {
      const current = this.queue[0];
      const available = current.length - this.queueOffset;
      const copyLength = Math.min(available, output.length - outputOffset);
      output.set(
        current.subarray(this.queueOffset, this.queueOffset + copyLength),
        outputOffset
      );
      this.queueOffset += copyLength;
      outputOffset += copyLength;
      this.bufferedSamples -= copyLength;
      if (this.queueOffset === current.length) {
        this.queue.shift();
        this.queueOffset = 0;
      }
    }

    if (this.isPlaying && outputOffset === 0) {
      this.emptyRenderCount += 1;
      const emptyRenderLimit = Math.ceil(
        (sampleRate * UNDERFLOW_GRACE_SECONDS) / RENDER_QUANTUM_SAMPLES
      );
      if (this.emptyRenderCount >= emptyRenderLimit) this.clear();
    } else {
      this.emptyRenderCount = 0;
    }
    return true;
  }
}

registerProcessor('voice-preview-output', VoicePreviewOutputProcessor);
