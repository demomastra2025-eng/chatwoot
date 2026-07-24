class VoicePreviewInputProcessor extends AudioWorkletProcessor {
  process(inputs, outputs) {
    const samples = inputs[0]?.[0];
    if (!samples?.length) return true;

    const output = outputs[0]?.[0];
    if (output) output.set(samples);
    const captured = samples.slice();
    this.port.postMessage(captured, [captured.buffer]);
    return true;
  }
}

registerProcessor('voice-preview-input', VoicePreviewInputProcessor);
