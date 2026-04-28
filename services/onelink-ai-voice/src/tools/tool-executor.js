const { withTimeout, safeReason } = require('../utils/timeout');
const { sanitizeErrorMessage } = require('../utils/errors');

class ToolExecutor {
  constructor({ client, callRef, timeoutMs = 800, scopeProvider = () => ({}) } = {}) {
    if (!client) throw new Error('client is required');
    if (!callRef) throw new Error('callRef is required');
    this.client = client;
    this.callRef = callRef;
    this.timeoutMs = timeoutMs;
    this.scopeProvider = scopeProvider;
  }

  async execute(name, args = {}, metadata = {}) {
    const toolName = String(name || '').trim();
    const baseMetadata = { ...metadata, tool_name: toolName };
    await this.safeControl('tool_started', baseMetadata);

    try {
      const result = await withTimeout(
        this.client.callTool(toolName, this.scopedPayload({ arguments: args })),
        this.timeoutMs,
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
  }

  scopedPayload(extra = {}) {
    return {
      call_ref: this.callRef,
      ...compactPayload(this.scopeProvider()),
      ...extra
    };
  }
}

function compactPayload(payload = {}) {
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = { ToolExecutor };
