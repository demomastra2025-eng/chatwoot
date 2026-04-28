const { normalizeTranscriptItem, transcriptKey } = require('../sessions/session-registry');

class TranscriptBuffer {
  constructor({ client, callRef, flushSize = 10 } = {}) {
    if (!client) throw new Error('client is required');
    if (!callRef) throw new Error('callRef is required');
    this.client = client;
    this.callRef = callRef;
    this.flushSize = flushSize;
    this.pending = [];
    this.seen = new Set();
  }

  get pendingCount() {
    return this.pending.length;
  }

  add(item) {
    const normalized = normalizeTranscriptItem(item);
    if (!normalized) return null;
    const key = transcriptKey(normalized);
    if (this.seen.has(key)) return null;
    this.seen.add(key);
    this.pending.push(normalized);
    return normalized;
  }

  async addAndMaybeFlush(item) {
    const normalized = this.add(item);
    if (this.pending.length >= this.flushSize) {
      await this.flush({ final: Boolean(normalized?.final) });
    }
    return normalized;
  }

  async flush({ final = false } = {}) {
    if (this.pending.length === 0) return { status: 'noop', accepted: 0 };
    const items = this.pending.splice(0, this.pending.length);
    return this.client.sendTranscript({
      call_ref: this.callRef,
      final: Boolean(final || items.some((item) => item.final)),
      items
    });
  }
}

module.exports = { TranscriptBuffer };
