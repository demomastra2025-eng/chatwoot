const { TranscriptBuffer } = require('../transcripts/transcript-buffer');
const { normalizeAiResponseText } = require('../transcripts/ai-response-normalizer');
const { ToolExecutor } = require('../tools/tool-executor');
const { safeReason, withTimeout } = require('../utils/timeout');
const { randomUUID } = require('node:crypto');

class VoiceSession {
  constructor({ client, callRef, ingressNumber = null, callerNumber = null, numberRef = null, accountId = null, bridgeCallRef = null, toolTimeoutMs = 3_000 } = {}) {
    if (!client) throw new Error('client is required');
    if (!callRef) throw new Error('callRef is required');
    this.client = client;
    this.callRef = callRef;
    this.ingressNumber = ingressNumber;
    this.callerNumber = callerNumber;
    this.numberRef = numberRef;
    this.accountId = accountId;
    this.bridgeCallRef = bridgeCallRef;
    this.aiSessionId = `ai_${randomUUID()}`;
    this.startedAt = new Date();
    this.eventSeq = 0;
    this.closed = false;
    this.finalizeSent = false;
    this.finalizeInFlight = false;
    this.mediaSessionRef = null;
    this.streamRef = null;
    this.context = null;
    this.state = 'new';
    this.transcripts = new TranscriptBuffer({ client, callRef, scopeProvider: () => this.scopePayload() });
    this.transcriptFlushPromise = Promise.resolve();
    this.tools = new ToolExecutor({
      client,
      callRef,
      timeoutMs: toolTimeoutMs,
      timeoutProvider: toolName => this.toolTimeoutFor(toolName),
      scopeProvider: () => this.scopePayload(),
      eventSender: (action, metadata) => this.safeEvent(action, metadata)
    });
  }

  async bootstrap({ timeoutMs = null, context = null, source = 'onelink_context' } = {}) {
    const startedAt = Date.now();
    const effectiveTimeoutMs = timeoutMs ?? this.client.timeoutMs;
    try {
      const inlineContext = normalizeInlineContext(context);
      const contextRequest = inlineContext ? Promise.resolve(inlineContext) : Promise.resolve(this.client.getContext({
        call_ref: this.callRef,
        ingress_number: this.ingressNumber,
        caller_number: this.callerNumber,
        number_ref: this.numberRef,
        account_id: this.accountId
      }));
      void this.safeEvent('context_fetch_started', {
        timeout_ms: effectiveTimeoutMs,
        source: inlineContext ? source : 'onelink_context',
        inline: Boolean(inlineContext)
      });
      this.context = await withTimeout(contextRequest, effectiveTimeoutMs, 'voice context bootstrap');
      this.accountId = this.context.account_id || this.context.accountId || this.accountId;
      this.numberRef = this.context.number_ref || this.context.numberRef || this.numberRef;
      this.state = 'active';
      void this.safeEvent('context_fetch_ready', {
        duration_ms: Date.now() - startedAt,
        source: inlineContext ? source : 'onelink_context',
        inline: Boolean(inlineContext),
        provider: this.context.ai?.provider,
        model: this.context.ai?.model
      });
      void this.safeControl('ai_ringing', { provider: this.context.ai?.provider, model: this.context.ai?.model });
      void this.safeControl('ai_answered', { provider: this.context.ai?.provider, model: this.context.ai?.model });
      return this.context;
    } catch (error) {
      const reason = safeReason(error, 'context_unavailable');
      this.context = buildFallbackContext({
        callRef: this.callRef,
        reason,
        accountId: this.accountId,
        numberRef: this.numberRef,
        ingressNumber: this.ingressNumber,
        callerNumber: this.callerNumber,
        bridgeCallRef: this.bridgeCallRef
      });
      this.state = 'active';
      void this.safeEvent('context_fetch_failed', {
        duration_ms: Date.now() - startedAt,
        reason,
        degraded: true,
        fallback_provider: this.context.ai?.provider,
        fallback_model: this.context.ai?.model
      });
      void this.safeControl('ai_ringing', { provider: this.context.ai?.provider, model: this.context.ai?.model, degraded: true, reason });
      void this.safeControl('ai_answered', { provider: this.context.ai?.provider, model: this.context.ai?.model, degraded: true, reason });
      return this.context;
    }
  }

  recordCallerTranscript(text, options = {}) {
    return this.recordTranscript({ speaker: 'caller', text, ...options });
  }

  recordAiTranscript(text, options = {}) {
    const normalized = normalizeAiResponseText(text);
    if (!normalized) return null;

    return this.recordTranscript({ speaker: 'ai', ...options, ...normalized });
  }

  recordTranscript(item) {
    if (this.closed) return null;
    const normalized = this.transcripts.add(item);
    if (!normalized) return null;

    this.transcriptFlushPromise = this.transcriptFlushPromise
      .then(() => this.transcripts.flush({ final: Boolean(normalized.final) }))
      .catch(() => ({ status: 'failed', accepted: 0 }));
    return normalized;
  }

  flushTranscript(options = {}) {
    return this.transcripts.flush(options);
  }

  executeTool(name, args = {}, metadata = {}) {
    if (this.closed) return { ok: false, ignored: true, reason: 'session_closed' };
    return this.tools.execute(name, args, metadata);
  }

  toolTimeoutFor(name) {
    const normalizedName = String(name || '').trim();
    const tool = Array.isArray(this.context?.tools)
      ? this.context.tools.find(candidate => String(candidate?.name || '').trim() === normalizedName)
      : null;
    const parsed = Number.parseInt(tool?.timeout_ms ?? tool?.timeoutMs, 10);
    return parsed > 0 ? parsed : null;
  }

  async close(action = 'session_completed', metadata = {}) {
    if (this.closed) return;
    this.closed = true;
    await this.transcriptFlushPromise;
    await this.flushTranscript({ final: true });
    await this.safeControl(action, metadata);
    await this.safeFinalize(action, metadata);
    this.state = finalStatusForAction(action) === 'failed' ? 'failed' : 'completed';
  }

  async safeControl(action, metadata = {}) {
    if (this.closed && !terminalLifecycleAction(action)) return;
    let controlSent = false;
    try {
      await this.client.sendControl(this.scopedPayload({ action, metadata }));
      controlSent = true;
    } catch (_error) {
      // Realtime path remains live even if Rails control acknowledgement is temporarily unavailable.
    }
    if (!controlSent || !controlPersistsLifecycle(action)) {
      await this.safeEvent(action, metadata);
    }
  }

  async safeFinalize(action, metadata = {}) {
    if (typeof this.client.finalizeCall !== 'function') return;
    if (this.finalizeSent || this.finalizeInFlight) return;
    this.finalizeInFlight = true;

    try {
      const includePartialTranscript = Boolean(
        metadata.include_partial_transcript ||
        metadata.incomplete_transcript ||
        this.transcripts.hasPartialItems()
      );
      const finalTranscript = includePartialTranscript
        ? this.transcripts.finalItemsWithPartials()
        : this.transcripts.finalItems();
      await this.client.finalizeCall(this.scopedPayload({
        event_id: `finalize:${this.callRef}:${action}`,
        event_seq: this.nextEventSeq(),
        event_type: 'finalize',
        provider_call_id: this.callRef,
        bridge_call_ref: metadata.bridge_call_ref || this.bridgeCallRef,
        ai_runtime_call_ref: this.callRef,
        runtime_call_ref: this.callRef,
        ai_session_id: this.aiSessionId,
        provider_session_id: metadata.provider_session_id || this.aiSessionId,
        media_session_ref: metadata.media_session_ref || this.mediaSessionRef || undefined,
        stream_ref: metadata.stream_ref || this.streamRef || undefined,
        conversation_id: this.context?.conversation_id || this.context?.conversationId,
        status: metadata.final_status || finalStatusForAction(action),
        started_at: this.startedAt.toISOString(),
        reason: metadata.reason || action,
        ended_at: new Date().toISOString(),
        duration_ms: Math.max(0, Date.now() - this.startedAt.getTime()),
        final_transcript: finalTranscript,
        partial_transcript: this.transcripts.allItems().filter(item => item.final === false),
        incomplete_transcript: includePartialTranscript || undefined,
        summary: metadata.summary,
        transfer_result: metadata.transfer_result,
        recording_url: metadata.recording_url,
        recording_status: metadata.recording_status,
        degraded: metadata.degraded,
        missing_direction: metadata.missing_direction,
        media_stream_closed_after_audio: metadata.media_stream_closed_after_audio,
        last_ai_audio_at: metadata.last_ai_audio_at,
        last_caller_audio_at: metadata.last_caller_audio_at,
        last_media_write_at: metadata.last_media_write_at,
        source: metadata.source,
        close_code: metadata.close_code,
        close_reason: metadata.close_reason,
        error_code: metadata.error_code,
        error_message: metadata.error_message || metadata.reason
      }));
      this.finalizeSent = true;
    } catch (_error) {
      // Finalize is retried by the caller/runtime path; media cleanup must still complete.
    } finally {
      this.finalizeInFlight = false;
    }
  }

  async safeEvent(eventType, eventPayload = {}) {
    if (typeof this.client.sendEvent !== 'function') return;
    if (this.closed && !terminalLifecycleAction(eventType)) return;

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
      provider: eventPayload.provider || this.context?.ai?.provider || 'onelink_ai_voice',
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
      bridge_call_ref: this.bridgeCallRef,
      media_session_ref: this.mediaSessionRef,
      stream_ref: this.streamRef,
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
  if (normalized.includes('provider_error') || normalized.includes('provider_stream_closed') || normalized.includes('media_stream_closed') || normalized.includes('media_stream_framing_error') || normalized.includes('media_stream_not_established')) return 'failed';
  if (normalized.includes('provider_call_closed') || normalized.includes('runtime_closed')) return 'cancelled';
  if (normalized.includes('operator_unavailable') || normalized.includes('operator_no_answer')) return 'operator_unavailable';
  if (normalized.includes('transfer')) return 'transferred';
  return 'completed';
}

function terminalLifecycleAction(action) {
  const normalized = String(action || '').toLowerCase();
  return normalized.includes('completed') ||
    normalized.includes('failed') ||
    normalized.includes('cancelled') ||
    normalized.includes('caller_hangup') ||
    normalized.includes('provider_stream_closed') ||
    normalized.includes('media_stream_closed') ||
    normalized.includes('media_stream_framing_error') ||
    normalized.includes('media_stream_not_established') ||
    normalized.includes('provider_call_closed') ||
    normalized.includes('runtime_closed') ||
    normalized.includes('transfer_completed');
}

function controlPersistsLifecycle(action) {
  return String(action || '').trim() !== 'handoff_requested';
}

function compactPayload(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

function normalizeInlineContext(context) {
  if (!context || typeof context !== 'object') return null;
  const callRef = context.call_ref || context.callRef;
  if (!callRef && !context.ai && !context.captain) return null;
  return context;
}

function buildFallbackContext(options = {}, legacyReason = null) {
  const input = typeof options === 'string' ? { callRef: options, reason: legacyReason } : (options || {});
  const callRef = input.callRef || input.call_ref;
  const reason = input.reason || 'context_unavailable';
  return {
    call_ref: callRef,
    account_id: input.accountId || input.account_id,
    number_ref: input.numberRef || input.number_ref,
    ingress_number: input.ingressNumber || input.ingress_number,
    caller_number: input.callerNumber || input.caller_number,
    bridge_call_ref: input.bridgeCallRef || input.bridge_call_ref,
    ai: {
      provider: 'gemini-live',
      first_message: 'Здравствуйте, я голосовой ассистент. Слушаю вас.',
      system_prompt: [
        'Ты голосовой ассистент OneLink.',
        'CRM-контекст временно недоступен, поэтому отвечай коротко, не выдумывай факты о клиенте и задавай уточняющие вопросы.',
        'Если нужна информация из CRM или действие в системе, честно скажи, что уточнишь детали и попроси клиента сформулировать вопрос.'
      ].join('\n'),
      degraded: true,
      context_degraded: true,
      reason
    },
    tools: [],
    transfer: { enabled: false }
  };
}

module.exports = { VoiceSession, buildFallbackContext };
