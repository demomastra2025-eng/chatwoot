const { randomUUID } = require('node:crypto');
const { withTimeout, safeReason } = require('../utils/timeout');
const { sanitizeErrorMessage } = require('../utils/errors');

class ToolExecutor {
  constructor({ client, callRef, timeoutMs = 3_000, timeoutProvider = null, scopeProvider = () => ({}), eventSender = null } = {}) {
    if (!client) throw new Error('client is required');
    if (!callRef) throw new Error('callRef is required');
    this.client = client;
    this.callRef = callRef;
    this.timeoutMs = timeoutMs;
    this.timeoutProvider = timeoutProvider;
    this.scopeProvider = scopeProvider;
    this.eventSender = eventSender;
  }

  async execute(name, args = {}, metadata = {}) {
    const toolName = String(name || '').trim();
    const timeoutMs = this.timeoutFor(toolName);
    const requestId = metadata.request_id || metadata.requestId || metadata.tool_call_id || `tool_${randomUUID()}`;
    const baseMetadata = { ...metadata, tool_name: toolName, timeout_ms: timeoutMs, request_id: requestId };
    await this.safeControl('tool_started', baseMetadata);

    let timedOut = false;
    const toolPromise = Promise.resolve().then(() => (
      this.client.callTool(toolName, this.scopedPayload({ arguments: args, request_id: requestId }), { timeoutMs, requestId })
    ));

    toolPromise
      .then(result => {
        if (!timedOut) return null;
        return this.safeControl('tool_async_completed', { ...baseMetadata, ok: true, async: true, result_present: result !== undefined });
      })
      .catch(error => {
        if (!timedOut) return null;
        const reason = sanitizeErrorMessage(error.message || safeReason(error));
        return this.safeControl('tool_async_failed', { ...baseMetadata, ok: false, async: true, error: reason });
      });

    try {
      const result = await withTimeout(toolPromise, timeoutMs, `tool ${toolName}`);
      await this.safeControl('tool_completed', { ...baseMetadata, ok: true });
      return { ok: true, result };
    } catch (error) {
      const reason = sanitizeErrorMessage(error.message || safeReason(error));
      timedOut = isTimeoutError(error);
      await this.safeControl('tool_failed', { ...baseMetadata, ok: false, error: reason, pending: timedOut || undefined, async: timedOut || undefined });
      return { ok: false, fallback: true, error: reason, pending: timedOut || undefined, request_id: timedOut ? requestId : undefined };
    }
  }

  async safeControl(action, metadata = {}) {
    try {
      await this.client.sendControl(this.scopedPayload({ action, metadata }));
    } catch (_error) {
      // Control-plane acknowledgement must not block realtime audio/tool fallback.
    }
    try {
      await this.eventSender?.(action, metadata);
    } catch (_error) {
      // Event persistence is best effort from the realtime media path.
    }
  }

  scopedPayload(extra = {}) {
    return {
      call_ref: this.callRef,
      ...compactPayload(this.scopeProvider()),
      ...extra
    };
  }

  timeoutFor(toolName) {
    const candidate = typeof this.timeoutProvider === 'function' ? this.timeoutProvider(toolName) : null;
    const parsed = Number.parseInt(candidate, 10);
    return parsed > 0 ? parsed : this.timeoutMs;
  }
}

function isTimeoutError(error) {
  return error?.code === 'timeout' || /timed out/i.test(String(error?.message || ''));
}

function compactPayload(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = { ToolExecutor };
