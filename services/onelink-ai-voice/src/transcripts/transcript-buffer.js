const { normalizeTranscriptItem, transcriptKey } = require('../sessions/session-registry');

class TranscriptBuffer {
  constructor({ client, callRef, flushSize = 10, scopeProvider = () => ({}) } = {}) {
    if (!client) throw new Error('client is required');
    if (!callRef) throw new Error('callRef is required');
    this.client = client;
    this.callRef = callRef;
    this.flushSize = flushSize;
    this.scopeProvider = scopeProvider;
    this.pending = [];
    this.items = [];
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
    this.items.push(normalized);
    return normalized;
  }

  finalItems() {
    return this.items.filter((item) => item.final !== false);
  }

  finalItemsWithPartials() {
    const finals = this.finalItems();
    const keys = new Set(finals.map(item => transcriptKey(item)));
    const partials = this.items
      .filter(item => item.final === false)
      .map(item => ({ ...item, final: true, normalized_from: item.normalized_from || 'partial_transcript_fallback' }))
      .filter(item => !keys.has(transcriptKey(item)));

    return [...finals, ...partials];
  }

  hasPartialItems() {
    return this.items.some((item) => item.final === false);
  }

  allItems() {
    return [...this.items];
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
      ...compactPayload(this.scopeProvider()),
      final: Boolean(final || items.some((item) => item.final)),
      items
    });
  }
}

function compactPayload(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = { TranscriptBuffer };
