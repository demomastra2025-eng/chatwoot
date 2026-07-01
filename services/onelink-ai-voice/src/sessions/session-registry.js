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
    this.aliases = new Set([callRef]);
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
    this.aliases = new Map();
  }

  create(options = {}) {
    const callRef = normalizeRef(options.callRef || options.call_ref);
    const existing = this.get(callRef);
    if (existing) {
      this.update(existing.callRef, options);
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
    this.indexSession(session, options);
    return session;
  }

  get(callRef) {
    const primaryRef = this.primaryRef(callRef);
    if (!primaryRef) return undefined;

    const session = this.sessions.get(primaryRef);
    if (!session) {
      this.aliases.delete(normalizeRef(callRef));
      return undefined;
    }
    if (session.expired()) {
      this.deleteSession(session);
      return undefined;
    }
    return session;
  }

  update(callRef, attributes = {}) {
    const session = this.get(callRef);
    if (!session) return undefined;

    if (Object.prototype.hasOwnProperty.call(attributes, 'context')) {
      session.context = attributes.context || session.context;
    }
    session.accountId = attributes.accountId || attributes.account_id || session.accountId;
    session.state = attributes.state || session.state;
    if (attributes.metadata && typeof attributes.metadata === 'object') {
      session.metadata = { ...session.metadata, ...attributes.metadata };
    }
    if (attributes.routeDecision) session.routeDecision = attributes.routeDecision;
    this.indexSession(session, attributes);
    session.touch();
    return session;
  }

  close(callRef, reason = 'completed') {
    const session = this.get(callRef);
    if (!session) return undefined;
    session.close(reason);
    this.deleteSession(session);
    return session;
  }

  activeCount() {
    this.sweep();
    let count = 0;
    for (const session of this.sessions.values()) {
      if (!terminalState(session.state)) count += 1;
    }
    return count;
  }

  sweep() {
    let count = 0;
    for (const session of [...this.sessions.values()]) {
      if (session.expired()) {
        this.deleteSession(session);
        count += 1;
      }
    }
    return count;
  }

  primaryRef(callRef) {
    const ref = normalizeRef(callRef);
    if (!ref) return null;
    return this.sessions.has(ref) ? ref : this.aliases.get(ref);
  }

  indexSession(session, source = {}) {
    for (const ref of lifecycleRefs(source)) {
      session.aliases.add(ref);
      this.aliases.set(ref, session.callRef);
    }
    for (const ref of lifecycleRefs(source.context)) {
      session.aliases.add(ref);
      this.aliases.set(ref, session.callRef);
    }
    for (const ref of lifecycleRefs(source.routeDecision)) {
      session.aliases.add(ref);
      this.aliases.set(ref, session.callRef);
    }
  }

  deleteSession(session) {
    this.sessions.delete(session.callRef);
    for (const ref of session.aliases || []) {
      this.aliases.delete(ref);
    }
  }
}

function normalizeTranscriptItem(item = {}) {
  const text = String(item.text || '').trim();
  if (!text) return null;
  return compactPayload({
    speaker: ['caller', 'ai', 'operator', 'system'].includes(item.speaker) ? item.speaker : 'system',
    text,
    final: Boolean(item.final),
    at: item.at || item.occurred_at || item.occurredAt || new Date().toISOString(),
    raw_text: item.raw_text || item.rawText,
    reasoning: item.reasoning,
    artifact_ids: item.artifact_ids || item.artifactIds,
    handoff_message: item.handoff_message || item.handoffMessage,
    handoff_reason: item.handoff_reason || item.handoffReason,
    handoff_status_reason: item.handoff_status_reason || item.handoffStatusReason,
    normalized_from: item.normalized_from || item.normalizedFrom
  });
}

function compactPayload(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

function transcriptKey(item) {
  return [item.speaker, item.text, item.final ? '1' : '0', item.at].join('|');
}

function lifecycleRefs(source = {}) {
  if (!source || typeof source !== 'object') return [];
  return [
    source.callRef,
    source.call_ref,
    source.runtimeCallRef,
    source.runtime_call_ref,
    source.aiRuntimeCallRef,
    source.ai_runtime_call_ref,
    source.bridgeCallRef,
    source.bridge_call_ref,
    source.childCallRef,
    source.child_call_ref,
    source.parentCallRef,
    source.parent_call_ref,
    source.mediaSessionRef,
    source.media_session_ref,
    source.streamRef,
    source.stream_ref
  ].map(normalizeRef).filter(Boolean);
}

function normalizeRef(ref) {
  const normalized = String(ref || '').trim();
  return normalized || null;
}

function terminalState(state) {
  const normalized = String(state || '').toLowerCase();
  return ['completed', 'failed', 'cancelled', 'rejected', 'transferred'].includes(normalized) ||
    normalized.includes('completed') ||
    normalized.includes('failed') ||
    normalized.includes('cancelled') ||
    normalized.includes('rejected') ||
    normalized.includes('closed') ||
    normalized.includes('caller_hangup') ||
    normalized.includes('caller_hung_up') ||
    normalized.includes('transferred');
}

module.exports = { SessionRegistry, ManagedSession, normalizeTranscriptItem, transcriptKey };
