const { TranscriptBuffer } = require('../transcripts/transcript-buffer');
const { ToolExecutor } = require('../tools/tool-executor');
const { safeReason } = require('../utils/timeout');

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
    this.context = null;
    this.state = 'new';
    this.transcripts = new TranscriptBuffer({ client, callRef, scopeProvider: () => this.scopePayload() });
    this.tools = new ToolExecutor({ client, callRef, timeoutMs: toolTimeoutMs, scopeProvider: () => this.scopePayload() });
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
    await this.flushTranscript({ final: true });
    await this.safeControl(action, metadata);
    this.state = action.includes('failed') ? 'failed' : 'completed';
  }

  async safeControl(action, metadata = {}) {
    try {
      await this.client.sendControl(this.scopedPayload({ action, metadata }));
    } catch (_error) {
      // Realtime path remains live even if Rails control acknowledgement is temporarily unavailable.
    }
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
