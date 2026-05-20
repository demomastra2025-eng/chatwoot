const DEFAULT_TOOL_START_PROMPT_DELAY_MS = 700;
const DEFAULT_TOOL_PROMPT_MIN_INTERVAL_MS = 5_000;

class DialogueDirector {
  constructor({ context = {}, session = null, requestPayload = {}, sendText = null, setTimer = defaultSetTimer, clearTimer = defaultClearTimer, now = () => Date.now() } = {}) {
    this.context = context || {};
    this.settings = this.context.ai || {};
    this.session = session;
    this.requestPayload = requestPayload || {};
    this.sendText = typeof sendText === 'function' ? sendText : null;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this.now = typeof now === 'function' ? now : () => Date.now();
    this.timers = new Map();
    this.sequence = 0;
    this.lastPromptAt = 0;
  }

  startToolWait(toolCall = {}) {
    const toolName = normalizedToolName(toolCall.name);
    if (!this.sendText || !shouldPromptToolWait(toolName)) return;

    const sequence = ++this.sequence;
    this.cancelToolWait('rearmed');

    const startDelayMs = nonNegativeInteger(this.settings.tool_start_after_ms, DEFAULT_TOOL_START_PROMPT_DELAY_MS);
    const startTimer = this.setTimer(() => {
      if (sequence !== this.sequence || this.session?.closed) return;
      this.timers.delete('tool_start');
      this.sendPrompt('tool_wait_start', pickPhrase(this.settings.tool_start_phrases), {
        tool_name: toolName,
        tool_call_id: toolCall.id,
        delay_ms: startDelayMs
      });
    }, startDelayMs);
    this.timers.set('tool_start', startTimer);

    const delayMs = positiveInteger(this.settings.tool_delay_after_ms);
    if (!delayMs || delayMs <= startDelayMs) return;

    const delayTimer = this.setTimer(() => {
      if (sequence !== this.sequence || this.session?.closed) return;
      this.timers.delete('tool_delay');
      this.sendPrompt('tool_wait_delay', pickPhrase(this.settings.tool_delay_phrases), {
        tool_name: toolName,
        tool_call_id: toolCall.id,
        delay_ms: delayMs
      });
    }, delayMs);
    this.timers.set('tool_delay', delayTimer);
  }

  finishToolWait(toolCall = {}, toolResult = {}) {
    this.cancelToolWait('tool_finished');
    if (toolResult?.ok !== false) return;
    if (!this.sendText || !shouldPromptToolWait(normalizedToolName(toolCall.name))) return;

    this.sendPrompt('tool_wait_failed', pickPhrase(this.settings.tool_failure_phrases), {
      tool_name: normalizedToolName(toolCall.name),
      tool_call_id: toolCall.id
    });
  }

  cancelToolWait(_reason = 'cancelled') {
    for (const timerKey of ['tool_start', 'tool_delay']) {
      const timer = this.timers.get(timerKey);
      if (!timer) continue;
      this.clearTimer(timer);
      this.timers.delete(timerKey);
    }
  }

  close() {
    this.cancelToolWait('closed');
  }

  sendPrompt(kind, phrase, metadata = {}) {
    const text = cleanPhrase(phrase);
    if (!text || !this.sendText) return false;
    const minIntervalMs = nonNegativeInteger(this.settings.tool_prompt_min_interval_ms, DEFAULT_TOOL_PROMPT_MIN_INTERVAL_MS);
    const currentTime = this.now();
    if (minIntervalMs && this.lastPromptAt && currentTime - this.lastPromptAt < minIntervalMs) return false;

    try {
      this.sendText(`Произнеси клиенту коротко и дословно, без пояснений: ${text}`);
      this.lastPromptAt = currentTime;
    } catch (_error) {
      return false;
    }

    try {
      this.session?.safeEvent?.('dialogue_director_prompt', compactPayload({
        ...correlationPayload(this.session, this.requestPayload, this.context),
        kind,
        phrase: text,
        ...metadata
      }));
    } catch (_error) {
      // Dialogue prompts are best-effort and must not block realtime flow.
    }
    return true;
  }
}

function shouldPromptToolWait(toolName) {
  return !['request_transfer', 'transfer', 'end_call', 'hangup'].includes(toolName);
}

function normalizedToolName(value) {
  return String(value || '').trim().toLowerCase();
}

function pickPhrase(value) {
  if (Array.isArray(value)) return value.find(item => cleanPhrase(item));
  return cleanPhrase(value);
}

function cleanPhrase(value) {
  return String(value || '').trim();
}

function positiveInteger(value) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function nonNegativeInteger(value, fallback = 0) {
  if (value === undefined || value === null || value === '') return fallback;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function defaultSetTimer(handler, timeoutMs) {
  const timer = setTimeout(handler, timeoutMs);
  if (typeof timer.unref === 'function') timer.unref();
  return timer;
}

function defaultClearTimer(timer) {
  clearTimeout(timer);
}

function correlationPayload(session, requestPayload = {}, context = {}) {
  return compactPayload({
    call_ref: session?.callRef || requestPayload.call_ref || context.call_ref,
    bridge_call_ref: session?.bridgeCallRef || requestPayload.bridge_call_ref || context.bridge_call_ref,
    runtime_call_ref: session?.runtimeCallRef || requestPayload.runtime_call_ref || context.runtime_call_ref,
    account_id: session?.accountId || context.account_id,
    number_ref: session?.numberRef || context.number_ref,
    conversation_id: context.conversation_id,
    stream_ref: session?.streamRef,
    media_session_ref: session?.mediaSessionRef
  });
}

function compactPayload(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = { DialogueDirector };
