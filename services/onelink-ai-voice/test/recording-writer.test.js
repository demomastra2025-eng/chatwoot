const test = require('node:test');
const assert = require('node:assert/strict');
const { mkdtemp, readFile, rm } = require('node:fs/promises');
const { join } = require('node:path');
const { tmpdir } = require('node:os');
const { RecordingWriter } = require('../src/recordings/recording-writer');

test('RecordingWriter stores a playable OneLink-owned stereo WAV and emits recording_ready metadata to Rails', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'onelink-recording-'));
  const events = [];
  const client = { sendEvent: async payload => { events.push(payload); return { status: 'ok' }; } };

  try {
    const writer = new RecordingWriter({
      client,
      rootDir: dir,
      callRef: 'call-rec-1',
      accountId: 42,
      numberRef: 'num-1',
      startedAt: new Date('2026-05-15T10:00:00.000Z')
    });

    await writer.start({ sampleRate: 8000 });
    await writer.writeInbound(pcm16([1000, -1000]), { stream_ref: 'stream-1' });
    await writer.writeOutbound(pcm16([2000]), { stream_ref: 'stream-1' });
    const result = await writer.close({ endedAt: new Date('2026-05-15T10:00:03.000Z') });

    assert.equal(result.storage_key, 'voice-recordings/42/call-rec-1/recording.wav');
    assert.equal(result.content_type, 'audio/wav');
    assert.equal(result.channels, 2);
    assert.equal(result.layout, 'dual_channel_stereo');
    assert.deepEqual(result.channel_layout, { left: 'caller', right: 'voice_agent' });
    assert.equal(result.recorded_by, 'onelink-ai-voice');
    assert.equal(result.mode, 'ai_voice');
    assert.equal(result.sample_rate, 8000);
    assert.equal(result.inbound_bytes, 4);
    assert.equal(result.outbound_bytes, 2);
    assert.equal(events.length, 1);
    assert.equal(events[0].event_type, 'recording_ready');
    assert.equal(events[0].call_ref, 'call-rec-1');
    assert.equal(events[0].account_id, 42);
    assert.equal(events[0].number_ref, 'num-1');
    assert.equal(events[0].payload.storage_key, 'voice-recordings/42/call-rec-1/recording.wav');
    assert.equal(events[0].payload.byte_size, result.byte_size);
    assert.equal(events[0].payload.content_type, 'audio/wav');
    assert.equal(events[0].payload.layout, 'dual_channel_stereo');
    assert.deepEqual(events[0].payload.channel_layout, { left: 'caller', right: 'voice_agent' });
    assert.equal(events[0].metadata.recording.writer, 'onelink-ai-voice');

    const stored = await readFile(join(dir, result.storage_key));
    assert.equal(stored.subarray(0, 4).toString('ascii'), 'RIFF');
    assert.equal(stored.subarray(8, 12).toString('ascii'), 'WAVE');
    assert.equal(stored.readUInt16LE(22), 2);
    assert.equal(stored.readUInt32LE(24), 8000);
    assert.equal(stored.subarray(36, 40).toString('ascii'), 'data');
    assert.equal(stored.readUInt32LE(40), 12);
    assert.deepEqual(stereoSamples(stored.subarray(44)), [1000, 0, -1000, 0, 0, 2000]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('RecordingWriter serializes concurrent frame writes before finalizing the WAV header and checksum', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'onelink-recording-'));
  const events = [];
  const writer = new RecordingWriter({
    client: { sendEvent: async payload => { events.push(payload); return { status: 'ok' }; } },
    rootDir: dir,
    callRef: 'call-rec-concurrent',
    accountId: 42,
    startedAt: new Date('2026-05-15T10:00:00.000Z')
  });

  try {
    const writes = [
      writer.writeInbound(pcm16([1, 2])),
      writer.writeOutbound(pcm16([3, 4])),
      writer.writeInbound(pcm16([5]))
    ];
    const closePromise = writer.close({ endedAt: new Date('2026-05-15T10:00:01.000Z') });
    await Promise.all(writes);
    const result = await closePromise;
    const stored = await readFile(join(dir, result.storage_key));

    assert.equal(stored.readUInt32LE(40), stored.length - 44);
    assert.equal(stereoSamples(stored.subarray(44)).length, 10);
    assert.equal(result.sha256.length, 64);
    assert.equal(events[0].payload.sha256, result.sha256);
    assert.equal(events[0].payload.byte_size, stored.length);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('RecordingWriter reports distinct recording-scoped errors without sending raw audio to Rails', async () => {
  const events = [];
  const client = { sendEvent: async payload => { events.push(payload); return { status: 'ok' }; } };
  const writer = new RecordingWriter({
    client,
    rootDir: '/dev/null/not-a-directory',
    callRef: 'call-rec-fail',
    accountId: 42
  });

  const result = await writer.start();
  await writer.writeInbound(Buffer.from([1, 2]));

  assert.equal(result, false);
  assert.equal(events.length >= 1, true);
  assert.ok(new Set(events.map(event => event.event_key)).size === events.length);
  assert.ok(events.every(event => event.event_type === 'error'));
  assert.ok(events.every(event => event.payload.scope === 'recording'));
  assert.equal(events.some(event => Object.prototype.hasOwnProperty.call(event.payload, 'data')), false);
});

function pcm16(samples) {
  const buffer = Buffer.alloc(samples.length * 2);
  samples.forEach((sample, index) => buffer.writeInt16LE(sample, index * 2));
  return buffer;
}

function stereoSamples(buffer) {
  const samples = [];
  for (let offset = 0; offset < buffer.length; offset += 2) {
    samples.push(buffer.readInt16LE(offset));
  }
  return samples;
}
