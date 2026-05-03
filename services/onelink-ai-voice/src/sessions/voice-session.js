const { TranscriptBuffer } = require('../transcripts/transcript-buffer');
const { ToolExecutor } = require('../tools/tool-executor');
const { safeReason } = require('../utils/timeout');
const { randomUUID } = require('node:crypto');

class VoiceSession {
  constructor({ client, callRef, ingressNumber = null, callerNumber = null, numberRef = null, accountId = null, toolTimeoutMs = 3_000 } = {}) {
    if (!client) throw new Error('client is required');
    if (!callRef) throw new Error('callRef is required');
    this.client = client;
    this.callRef = callRef;
    this.ingressNumber = ingressNumber;
    this.callerNumber = callerNumber;
    this.numberRef = numberRef;
    this.accountId = accountId;
    this.aiSessionId = `ai_${randomUUID()}`;
    this.startedAt = new Date();
    this.eventSeq = 0;
    this.closed = false;
    this.context = null;
    this.state = 'new';
    this.transcripts = new TranscriptBuffer({ client, callRef, scopeProvider: () => this.scopePayload() });
    this.tools = new ToolExecutor({
      client,
      callRef,
      timeoutMs: toolTimeoutMs,
      scopeProvider: () => this.scopePayload(),
      eventSender: (action, metadata) => this.safeEvent(action, metadata)
    });
  }

  async bootstrap() {
    try {
      this.context = await this.client.getContext({
        call_ref: this.callRef,
        ingress_number: this.ingressNumber,
        caller_number: this.callerNumber,
        number_ref: this.numberRef,
        account_id: this.accountId
      });
      this.accountId = this.context.account_id || this.context.accountId || this.accountId;
      this.numberRef = this.context.number_ref || this.context.numberRef || this.numberRef;
      this.state = 'active';
      await this.safeControl('ai_ringing', { provider: this.context.ai?.provider, model: this.context.ai?.model });
      await this.safeControl('ai_answered', { provider: this.context.ai?.provider, model: this.context.ai?.model });
      return this.context;
    } catch (error) {
      this.state = 'fallback';
      const reason = safeReason(error, 'context_unavailable');
      this.context = buildFallbackContext(this.callRef, reason);
      await this.safeControl('session_failed', { reason });
      return this.context;
    }
  }

  recordCallerTranscript(text, options = {}) {
    return this.transcripts.add({ speaker: 'caller', text, ...options });
  }

  recordAiTranscript(text, options = {}) {
    return this.transcripts.add({ speaker: 'ai', text, ...options });
  }

  flushTranscript(options = {}) {
    return this.transcripts.flush(options);
  }

  executeTool(name, args = {}, metadata = {}) {
    return this.tools.execute(name, args, metadata);
  }

  async close(action = 'session_completed', metadata = {}) {
    if (this.closed) return;
    this.closed = true;
    await this.flushTranscript({ final: true });
    await this.safeControl(action, metadata);
    await this.safeFinalize(action, metadata);
    this.state = action.includes('failed') ? 'failed' : 'completed';
  }

  async safeControl(action, metadata = {}) {
    try {
      await this.client.sendControl(this.scopedPayload({ action, metadata }));
    } catch (_error) {
      // Realtime path remains live even if Rails control acknowledgement is temporarily unavailable.
    }
    await this.safeEvent(action, metadata);
  }

  async safeFinalize(action, metadata = {}) {
    if (typeof this.client.finalizeCall !== 'function') return;

    try {
      await this.client.finalizeCall(this.scopedPayload({
        event_id: `finalize:${this.callRef}:${action}`,
        event_seq: this.nextEventSeq(),
        event_type: 'finalize',
        provider_call_id: this.callRef,
        ai_session_id: this.aiSessionId,
        conversation_id: this.context?.conversation_id || this.context?.conversationId,
        status: metadata.final_status || finalStatusForAction(action),
        started_at: this.startedAt.toISOString(),
        reason: metadata.reason || action,
        ended_at: new Date().toISOString(),
        duration_ms: Math.max(0, Date.now() - this.startedAt.getTime()),
        final_transcript: this.transcripts.finalItems(),
        summary: metadata.summary,
        transfer_result: metadata.transfer_result,
        recording_url: metadata.recording_url,
        error_code: metadata.error_code,
        error_message: metadata.error_message || metadata.reason
      }));
    } catch (_error) {
      // Finalize is retried by the caller/runtime path; media cleanup must still complete.
    }
  }

  async safeEvent(eventType, eventPayload = {}) {
    if (typeof this.client.sendEvent !== 'function') return;

    try {
      await this.client.sendEvent(this.eventPayload(eventType, eventPayload));
    } catch (_error) {
      // Event persistence must not block realtime media handling.
    }
  }

  eventPayload(eventType, eventPayload = {}) {
    const seq = this.nextEventSeq();
    return this.scopedPayload({
      event_id: `evt:${this.callRef}:${seq}:${eventType}`,
      event_seq: seq,
      event_type: eventType,
      provider: 'fonoster',
      provider_call_id: this.callRef,
      ai_session_id: this.aiSessionId,
      conversation_id: this.context?.conversation_id || this.context?.conversationId,
      occurred_at: new Date().toISOString(),
      attempt: 1,
      payload: eventPayload
    });
  }

  nextEventSeq() {
    this.eventSeq += 1;
    return this.eventSeq;
  }

  scopedPayload(extra = {}) {
    return {
      call_ref: this.callRef,
      ...compactPayload(this.scopePayload()),
      ...extra
    };
  }

  scopePayload() {
    return {
      account_id: this.accountId,
      number_ref: this.numberRef,
      ingress_number: this.ingressNumber,
      caller_number: this.callerNumber
    };
  }
}

function finalStatusForAction(action) {
  const normalized = String(action || '').toLowerCase();
  if (normalized.includes('failed')) return 'failed';
  if (normalized.includes('caller_hangup')) return 'caller_hung_up';
  if (normalized.includes('operator_unavailable') || normalized.includes('operator_no_answer')) return 'operator_unavailable';
  if (normalized.includes('transfer')) return 'transferred';
  return 'completed';
}

function compactPayload(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

function buildFallbackContext(callRef, reason) {
  return {
    call_ref: callRef,
    ai: {
      provider: 'scripted-fallback',
      model: 'local-scripted',
      first_message: 'Извините, голосовой ассистент временно недоступен. Сейчас попробую соединить вас со специалистом.',
      reason
    },
    tools: [],
    transfer: { enabled: false }
  };
}

module.exports = { VoiceSession, buildFallbackContext };
