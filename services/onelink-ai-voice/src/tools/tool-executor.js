/* eslint-disable no-use-before-define */
const { randomUUID } = require('node:crypto');
const { withTimeout, safeReason } = require('../utils/timeout');
const { sanitizeErrorMessage } = require('../utils/errors');

const DEFAULT_DUPLICATE_WINDOW_MS = 30_000;
const DEFAULT_DUPLICATE_LIMIT = 2;
const TRACE_PREVIEW_LIMIT = 4_000;
const SENSITIVE_KEY_PATTERN =
  /token|secret|password|authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|credential|cookie|phone|телефон/i;

class ToolExecutor {
  constructor({
    client,
    callRef,
    timeoutMs = 3_000,
    timeoutProvider = null,
    scopeProvider = () => ({}),
    eventSender = null,
    duplicateWindowMs = DEFAULT_DUPLICATE_WINDOW_MS,
    duplicateLimit = DEFAULT_DUPLICATE_LIMIT,
  } = {}) {
    if (!client) throw new Error('client is required');
    if (!callRef) throw new Error('callRef is required');
    this.client = client;
    this.callRef = callRef;
    this.timeoutMs = timeoutMs;
    this.timeoutProvider = timeoutProvider;
    this.scopeProvider = scopeProvider;
    this.eventSender = eventSender;
    this.duplicateWindowMs = duplicateWindowMs;
    this.duplicateLimit = duplicateLimit;
    this.recentCalls = new Map();
  }

  async execute(name, args = {}, metadata = {}) {
    const toolName = String(name || '').trim();
    const timeoutMs = this.timeoutFor(toolName);
    const {
      onAsyncResult,
      foreground_timeout_ms: foregroundTimeoutSnake,
      foregroundTimeoutMs,
      ...eventMetadata
    } = metadata || {};
    const foregroundTimeoutMsCandidate =
      foregroundTimeoutSnake ?? foregroundTimeoutMs;
    const waitTimeoutMs = foregroundTimeoutFor(
      foregroundTimeoutMsCandidate,
      timeoutMs
    );
    const requestId =
      eventMetadata.request_id ||
      eventMetadata.requestId ||
      eventMetadata.tool_call_id ||
      `tool_${randomUUID()}`;
    const traceInput = sanitizeTracePayload(args);
    const baseMetadata = {
      ...eventMetadata,
      tool_name: toolName,
      timeout_ms: timeoutMs,
      foreground_timeout_ms: waitTimeoutMs,
      request_id: requestId,
      input: traceInput,
    };
    const duplicate = this.duplicateStatus(toolName, args);
    if (duplicate.suppressed) {
      const suppressedResult = duplicateSuppressedResult(toolName, duplicate);
      await this.safeControl('tool_suppressed', {
        ...baseMetadata,
        ok: true,
        suppressed: true,
        duplicate: true,
        duplicate_count: duplicate.count,
        duplicate_window_ms: this.duplicateWindowMs,
      });
      return {
        ok: true,
        result: suppressedResult,
        suppressed: true,
        duplicate: true,
      };
    }
    await this.safeControl('tool_started', baseMetadata);

    let timedOut = false;
    const toolPromise = Promise.resolve().then(() =>
      this.client.callTool(
        toolName,
        this.scopedPayload({ arguments: args, request_id: requestId }),
        { timeoutMs, requestId }
      )
    );

    toolPromise
      .then(result => {
        if (!timedOut) return null;
        notifyAsyncResult(onAsyncResult, {
          ok: true,
          async: true,
          tool_name: toolName,
          request_id: requestId,
          tool_call_id: baseMetadata.tool_call_id,
          result,
        });
        return this.safeControl('tool_async_completed', {
          ...baseMetadata,
          ok: true,
          async: true,
          result_present: result !== undefined,
          output: sanitizeTracePayload(result),
        });
      })
      .catch(error => {
        if (!timedOut) return null;
        const reason = sanitizeErrorMessage(error.message || safeReason(error));
        notifyAsyncResult(onAsyncResult, {
          ok: false,
          async: true,
          tool_name: toolName,
          request_id: requestId,
          tool_call_id: baseMetadata.tool_call_id,
          error: reason,
        });
        return this.safeControl('tool_async_failed', {
          ...baseMetadata,
          ok: false,
          async: true,
          error: reason,
        });
      });

    try {
      const result = await withTimeout(
        toolPromise,
        waitTimeoutMs,
        `tool ${toolName}`
      );
      this.recordSuccessfulCall(toolName, args);
      await this.safeControl('tool_completed', {
        ...baseMetadata,
        ok: true,
        output: sanitizeTracePayload(result),
      });
      return { ok: true, result };
    } catch (error) {
      const reason = sanitizeErrorMessage(error.message || safeReason(error));
      timedOut = isTimeoutError(error);
      await this.safeControl('tool_failed', {
        ...baseMetadata,
        ok: false,
        error: reason,
        pending: timedOut || undefined,
        async: timedOut || undefined,
      });
      return {
        ok: false,
        fallback: true,
        error: reason,
        pending: timedOut || undefined,
        request_id: timedOut ? requestId : undefined,
      };
    }
  }

  async safeControl(action, metadata = {}) {
    let controlSent = false;
    try {
      await this.client.sendControl(this.scopedPayload({ action, metadata }));
      controlSent = true;
    } catch (_error) {
      // Control-plane acknowledgement must not block realtime audio/tool fallback.
    }
    if (!controlSent) {
      try {
        await this.eventSender?.(action, metadata);
      } catch (_error) {
        // Event persistence is best effort from the realtime media path.
      }
    }
  }

  scopedPayload(extra = {}) {
    return {
      call_ref: this.callRef,
      ...compactPayload(this.scopeProvider()),
      ...extra,
    };
  }

  timeoutFor(toolName) {
    const candidate =
      typeof this.timeoutProvider === 'function'
        ? this.timeoutProvider(toolName)
        : null;
    const parsed = Number.parseInt(candidate, 10);
    return parsed > 0 ? parsed : this.timeoutMs;
  }

  duplicateStatus(toolName, args = {}) {
    const now = Date.now();
    const key = stableToolKey(toolName, args);
    const current = this.recentCalls.get(key);
    if (!current || now - current.firstAt > this.duplicateWindowMs)
      return { key, count: 0, toolName, suppressed: false };

    return { ...current, suppressed: current.count >= this.duplicateLimit };
  }

  recordSuccessfulCall(toolName, args = {}) {
    const now = Date.now();
    const key = stableToolKey(toolName, args);
    const current = this.recentCalls.get(key);
    if (!current || now - current.firstAt > this.duplicateWindowMs) {
      this.recentCalls.set(key, {
        key,
        count: 1,
        firstAt: now,
        lastAt: now,
        toolName,
      });
      return;
    }

    current.count += 1;
    current.lastAt = now;
    this.recentCalls.set(key, current);
  }
}

function foregroundTimeoutFor(candidate, timeoutMs) {
  const parsed = Number.parseInt(candidate, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return timeoutMs;
  return Math.min(parsed, timeoutMs);
}

async function notifyAsyncResult(handler, payload = {}) {
  if (typeof handler !== 'function') return;
  try {
    await handler(payload);
  } catch (_error) {
    // Late-result injection must never reject the original tool promise chain.
  }
}

function isTimeoutError(error) {
  return (
    error?.code === 'timeout' || /timed out/i.test(String(error?.message || ''))
  );
}

function duplicateSuppressedResult(toolName, duplicate = {}) {
  return {
    action: 'tool_suppressed',
    tool_name: toolName,
    duplicate: true,
    duplicate_count: duplicate.count,
    message: `The same ${toolName} request was already executed in this call. Do not call it again with the same arguments; continue the spoken answer using the previous result or say that no matching information was found.`,
  };
}

function stableToolKey(toolName, args = {}) {
  return `${String(toolName || '')
    .trim()
    .toLowerCase()}:${stableStringify(normalizeValue(args))}`;
}

function normalizeValue(value) {
  if (Array.isArray(value)) return value.map(normalizeValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map(key => [key, normalizeValue(value[key])])
    );
  }
  if (typeof value === 'string') return value.trim().toLowerCase();
  return value;
}

function stableStringify(value) {
  try {
    return JSON.stringify(value);
  } catch (_error) {
    return String(value);
  }
}

function sanitizeTracePayload(value, depth = 0) {
  if (value === undefined || value === null) return value;
  if (depth > 8) return '[TRUNCATED]';

  if (Array.isArray(value)) {
    return value.map(item => sanitizeTracePayload(item, depth + 1));
  }

  if (value instanceof Error) {
    return sanitizeTraceString(`${value.name}: ${value.message}`);
  }

  if (value && typeof value === 'object') {
    return Object.entries(value).reduce((acc, [key, childValue]) => {
      acc[key] = SENSITIVE_KEY_PATTERN.test(key)
        ? '[REDACTED]'
        : sanitizeTracePayload(childValue, depth + 1);
      return acc;
    }, {});
  }

  if (typeof value === 'string') return sanitizeTraceString(value);
  return value;
}

function sanitizeTraceString(value) {
  const parsed = parseTraceJson(value);
  if (parsed !== null) return trimTracePreview(JSON.stringify(parsed));

  const redacted = value
    .replace(/Bearer\s+[A-Za-z0-9._-]+/g, 'Bearer [REDACTED]')
    .replace(
      /(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)=([^\s&]+)/gi,
      '$1=[REDACTED]'
    )
    .replace(
      /(["']?)(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|authorization|credential|cookie|phone|телефон)\1\s*:\s*(["'])(?:\\.|(?!\3).)*\3/gi,
      '$1$2$1: $3[REDACTED]$3'
    )
    .replace(
      /(["']?)(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|authorization|credential|cookie|phone|телефон)\1\s*:\s*([^,}\s]+)/gi,
      '$1$2$1: [REDACTED]'
    );
  return trimTracePreview(redacted);
}

function trimTracePreview(value) {
  return value.length > TRACE_PREVIEW_LIMIT
    ? `${value.slice(0, TRACE_PREVIEW_LIMIT)}…`
    : value;
}

function parseTraceJson(value) {
  const trimmed = value.trim();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return null;
  try {
    return sanitizeTracePayload(JSON.parse(trimmed));
  } catch (_error) {
    return null;
  }
}

function compactPayload(payload = {}) {
  return Object.fromEntries(
    Object.entries(payload).filter(
      ([, value]) => value !== undefined && value !== null && value !== ''
    )
  );
}

module.exports = { ToolExecutor };
