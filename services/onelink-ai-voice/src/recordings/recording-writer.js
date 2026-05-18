const { createReadStream } = require('node:fs');
const { mkdir, open, stat } = require('node:fs/promises');
const { dirname, join } = require('node:path');
const { createHash, randomUUID } = require('node:crypto');

const DEFAULT_CONTENT_TYPE = 'audio/wav';
const DEFAULT_SAMPLE_RATE = 8000;
const CHANNELS = 2;
const BITS_PER_SAMPLE = 16;
const WAV_HEADER_BYTES = 44;

class RecordingWriter {
  constructor({
    client,
    rootDir = process.env.VOICE_AGENT_RECORDING_ROOT || '/app/storage',
    callRef,
    accountId = null,
    numberRef = null,
    bridgeCallRef = null,
    startedAt = new Date(),
    sampleRate = DEFAULT_SAMPLE_RATE,
    contentType = DEFAULT_CONTENT_TYPE
  } = {}) {
    if (!client) throw new Error('client is required');
    if (!callRef) throw new Error('callRef is required');
    this.client = client;
    this.rootDir = rootDir;
    this.callRef = callRef;
    this.accountId = accountId;
    this.numberRef = numberRef;
    this.bridgeCallRef = bridgeCallRef;
    this.startedAt = startedAt instanceof Date ? startedAt : new Date(startedAt);
    this.sampleRate = positiveInteger(sampleRate, DEFAULT_SAMPLE_RATE);
    this.contentType = contentType;
    this.storageKey = storageKeyFor({ accountId, callRef });
    this.path = join(rootDir, this.storageKey);
    this.started = false;
    this.closed = false;
    this.file = null;
    this.startPromise = null;
    this.queue = Promise.resolve();
    this.dataBytes = 0;
    this.inboundBytes = 0;
    this.outboundBytes = 0;
    this.errorSeq = 0;
    this.digest = null;
  }

  async start(options = {}) {
    if (this.started) return true;
    if (this.startPromise) return this.startPromise;
    if (options.sampleRate) this.sampleRate = positiveInteger(options.sampleRate, this.sampleRate);

    this.startPromise = (async () => {
      await mkdir(dirname(this.path), { recursive: true });
      this.file = await open(this.path, 'w');
      await this.file.write(wavHeader({ sampleRate: this.sampleRate, dataBytes: 0 }), 0, WAV_HEADER_BYTES, 0);
      this.started = true;
      return true;
    })();

    try {
      return await this.startPromise;
    } catch (error) {
      await this.cleanupFailedStart();
      this.startPromise = null;
      await this.reportError('recording_writer_failed', error);
      return false;
    }
  }

  writeInbound(chunk, metadata = {}) {
    return this.writeFrame('inbound', chunk, metadata);
  }

  writeOutbound(chunk, metadata = {}) {
    return this.writeFrame('outbound', chunk, metadata);
  }

  writeFrame(direction, chunk, _metadata = {}) {
    if (this.closed || !chunk) return Promise.resolve(false);

    const mono = normalizePcm16(chunk);
    if (mono.length === 0) return Promise.resolve(false);
    const stereo = stereoFrame(direction, mono);

    const writePromise = this.queue.then(async () => {
      const started = await this.start();
      if (!started || this.closed) return false;

      await this.file.write(stereo, 0, stereo.length, WAV_HEADER_BYTES + this.dataBytes);
      this.dataBytes += stereo.length;
      if (direction === 'inbound') this.inboundBytes += mono.length;
      if (direction === 'outbound') this.outboundBytes += mono.length;
      return true;
    }).catch(async error => {
      await this.reportError('recording_write_failed', error);
      return false;
    });

    this.queue = writePromise;
    return writePromise;
  }

  async close({ endedAt = new Date() } = {}) {
    if (this.closed) return this.resultPayload({ endedAt });
    const started = await this.start();
    if (!started) return null;

    await this.queue;
    this.closed = true;

    try {
      await this.file.write(wavHeader({ sampleRate: this.sampleRate, dataBytes: this.dataBytes }), 0, WAV_HEADER_BYTES, 0);
      await this.file.close();
      this.file = null;
      const payload = await this.resultPayload({ endedAt });
      await this.client.sendEvent(this.eventPayload('recording_ready', payload));
      return payload;
    } catch (error) {
      await this.reportError('recording_close_failed', error);
      return null;
    }
  }

  async resultPayload({ endedAt = new Date() } = {}) {
    const fileStat = await stat(this.path);
    const ended = endedAt instanceof Date ? endedAt : new Date(endedAt);
    this.digest ||= await sha256File(this.path);
    return {
      recording_ref: this.storageKey,
      storage_key: this.storageKey,
      byte_size: fileStat.size,
      content_type: this.contentType,
      sha256: this.digest,
      duration_ms: Math.max(0, Math.round((this.dataBytes / (this.sampleRate * CHANNELS * (BITS_PER_SAMPLE / 8))) * 1000)),
      wall_duration_ms: Math.max(0, ended.getTime() - this.startedAt.getTime()),
      writer: 'onelink-ai-voice',
      storage_provider: 'onelink_storage',
      sample_rate: this.sampleRate,
      channels: CHANNELS,
      bits_per_sample: BITS_PER_SAMPLE,
      inbound_bytes: this.inboundBytes,
      outbound_bytes: this.outboundBytes,
      recorded_by: 'onelink-ai-voice',
      mode: 'ai_voice',
      layout: 'dual_channel_stereo',
      channel_layout: {
        left: 'caller',
        right: 'voice_agent'
      }
    };
  }

  eventPayload(eventType, eventPayload, eventKey = null) {
    const id = eventKey || `recording:${this.callRef}:${eventType}`;
    return compact({
      event_id: id,
      event_key: id,
      event_type: eventType,
      call_ref: this.callRef,
      account_id: this.accountId,
      number_ref: this.numberRef,
      bridge_call_ref: this.bridgeCallRef,
      occurred_at: new Date().toISOString(),
      payload: eventPayload,
      metadata: {
        recording: {
          writer: 'onelink-ai-voice',
          storage_provider: 'onelink_storage'
        }
      }
    });
  }

  async reportError(code, error) {
    if (typeof this.client.sendEvent !== 'function') return;
    const sequence = ++this.errorSeq;
    const eventKey = `recording:${this.callRef}:error:${sequence}:${code}`;
    try {
      await this.client.sendEvent(this.eventPayload('error', {
        scope: 'recording',
        error_code: code,
        error_message: sanitizeError(error),
        retryable: retryableError(code)
      }, eventKey));
    } catch (_sendError) {
      // Recording errors must not break realtime media handling.
    }
  }

  async cleanupFailedStart() {
    this.started = false;
    const file = this.file;
    this.file = null;
    if (!file || typeof file.close !== 'function') return;

    try {
      await file.close();
    } catch (_closeError) {
      // Best effort cleanup; the original startup failure is reported separately.
    }
  }
}

function storageKeyFor({ accountId, callRef }) {
  const account = sanitizePathPart(accountId || 'unknown-account');
  const call = sanitizePathPart(callRef || randomUUID());
  return `voice-recordings/${account}/${call}/recording.wav`;
}

function sanitizePathPart(value) {
  return String(value || '').replace(/[^a-zA-Z0-9_.-]+/g, '-').replace(/^-+|-+$/g, '') || 'unknown';
}

function normalizePcm16(chunk) {
  const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk || []);
  if (buffer.length < 2) return Buffer.alloc(0);
  const data = extractWavData(buffer) || buffer;
  const evenLength = data.length - (data.length % 2);
  if (evenLength <= 0) return Buffer.alloc(0);
  return Buffer.from(data.subarray(0, evenLength));
}

function extractWavData(buffer) {
  if (buffer.length < 44) return null;
  if (buffer.subarray(0, 4).toString('ascii') !== 'RIFF' || buffer.subarray(8, 12).toString('ascii') !== 'WAVE') return null;

  let offset = 12;
  while (offset + 8 <= buffer.length) {
    const chunkId = buffer.subarray(offset, offset + 4).toString('ascii');
    const chunkSize = buffer.readUInt32LE(offset + 4);
    const dataStart = offset + 8;
    const dataEnd = Math.min(dataStart + chunkSize, buffer.length);
    if (chunkId === 'data') return buffer.subarray(dataStart, dataEnd);
    offset = dataStart + chunkSize + (chunkSize % 2);
  }
  return null;
}

function stereoFrame(direction, mono) {
  const samples = Math.floor(mono.length / 2);
  const output = Buffer.alloc(samples * CHANNELS * 2);
  const inbound = direction === 'inbound';
  const outbound = direction === 'outbound';

  for (let index = 0; index < samples; index += 1) {
    const sample = mono.readInt16LE(index * 2);
    const offset = index * 4;
    output.writeInt16LE(inbound ? sample : 0, offset);
    output.writeInt16LE(outbound ? sample : 0, offset + 2);
  }
  return output;
}

function wavHeader({ sampleRate, dataBytes }) {
  const byteRate = sampleRate * CHANNELS * (BITS_PER_SAMPLE / 8);
  const blockAlign = CHANNELS * (BITS_PER_SAMPLE / 8);
  const header = Buffer.alloc(WAV_HEADER_BYTES);
  header.write('RIFF', 0, 'ascii');
  header.writeUInt32LE(36 + dataBytes, 4);
  header.write('WAVE', 8, 'ascii');
  header.write('fmt ', 12, 'ascii');
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(CHANNELS, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(BITS_PER_SAMPLE, 34);
  header.write('data', 36, 'ascii');
  header.writeUInt32LE(dataBytes, 40);
  return header;
}

function sha256File(path) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    const stream = createReadStream(path);
    stream.on('data', chunk => hash.update(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

function sanitizeError(error) {
  return String(error?.message || error || 'recording error').replace(/Bearer\s+\S+/gi, 'Bearer [redacted]').slice(0, 240);
}

function retryableError(code) {
  return ['recording_writer_failed', 'recording_write_failed', 'recording_close_failed'].includes(code);
}

function positiveInteger(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function compact(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = { RecordingWriter, DEFAULT_CONTENT_TYPE };
