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
    const baseMetadata = { ...metadata, tool_name: toolName, timeout_ms: timeoutMs };
    await this.safeControl('tool_started', baseMetadata);

    try {
      const result = await withTimeout(
        this.client.callTool(toolName, this.scopedPayload({ arguments: args }), { timeoutMs }),
        timeoutMs,
        `tool ${toolName}`
      );
      await this.safeControl('tool_completed', { ...baseMetadata, ok: true });
      return { ok: true, result };
    } catch (error) {
      const reason = sanitizeErrorMessage(error.message || safeReason(error));
      await this.safeControl('tool_failed', { ...baseMetadata, ok: false, error: reason });
      return { ok: false, fallback: true, error: reason };
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

function compactPayload(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = { ToolExecutor };
