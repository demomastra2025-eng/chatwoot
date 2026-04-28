class ManagedSession {
  constructor({ callRef, accountId = null, context = {}, ttlMs = 3_600_000, maxHistory = 200, now = () => Date.now() } = {}) {
    if (!callRef) throw new Error('callRef is required');
    this.callRef = callRef;
    this.accountId = accountId;
    this.context = context || {};
    this.state = 'active';
    this.createdAt = now();
    this.updatedAt = this.createdAt;
    this.expiresAt = this.createdAt + ttlMs;
    this.maxHistory = maxHistory;
    this.now = now;
    this.transcript = [];
    this.controlEvents = [];
    this.metadata = {};
  }

  touch() {
    this.updatedAt = this.now();
  }

  addTranscript(item) {
    const normalized = normalizeTranscriptItem(item);
    if (!normalized) return null;

    const key = transcriptKey(normalized);
    this.transcript = this.transcript.filter((existing) => transcriptKey(existing) !== key);
    this.transcript.push(normalized);
    this.transcript = this.transcript.slice(-this.maxHistory);
    this.touch();
    return normalized;
  }

  addControlEvent(action, metadata = {}) {
    const event = { action, metadata, at: new Date(this.now()).toISOString() };
    this.controlEvents.push(event);
    this.controlEvents = this.controlEvents.slice(-100);
    this.touch();
    return event;
  }

  close(reason = 'completed') {
    this.state = reason;
    this.closedAt = this.now();
    this.touch();
  }

  expired() {
    return this.now() >= this.expiresAt;
  }
}

class SessionRegistry {
  constructor({ ttlMs = 3_600_000, maxHistory = 200, now = () => Date.now() } = {}) {
    this.ttlMs = ttlMs;
    this.maxHistory = maxHistory;
    this.now = now;
    this.sessions = new Map();
  }

  create(options = {}) {
    const callRef = options.callRef || options.call_ref;
    const existing = this.get(callRef);
    if (existing) {
      existing.context = options.context || existing.context;
      existing.accountId = options.accountId || options.account_id || existing.accountId;
      existing.touch();
      return existing;
    }

    const session = new ManagedSession({
      ...options,
      callRef,
      ttlMs: this.ttlMs,
      maxHistory: this.maxHistory,
      now: this.now
    });
    this.sessions.set(callRef, session);
    return session;
  }

  get(callRef) {
    const session = this.sessions.get(callRef);
    if (!session) return undefined;
    if (session.expired()) {
      this.sessions.delete(callRef);
      return undefined;
    }
    return session;
  }

  close(callRef, reason = 'completed') {
    const session = this.sessions.get(callRef);
    if (!session) return undefined;
    session.close(reason);
    this.sessions.delete(callRef);
    return session;
  }

  sweep() {
    let count = 0;
    for (const [callRef, session] of this.sessions.entries()) {
      if (session.expired()) {
        this.sessions.delete(callRef);
        count += 1;
      }
    }
    return count;
  }
}

function normalizeTranscriptItem(item = {}) {
  const text = String(item.text || '').trim();
  if (!text) return null;
  return {
    speaker: ['caller', 'ai', 'operator', 'system'].includes(item.speaker) ? item.speaker : 'system',
    text,
    final: Boolean(item.final),
    at: item.at || item.occurred_at || item.occurredAt || new Date().toISOString()
  };
}

function transcriptKey(item) {
  return [item.speaker, item.text, item.final ? '1' : '0', item.at].join('|');
}

module.exports = { SessionRegistry, ManagedSession, normalizeTranscriptItem, transcriptKey };
