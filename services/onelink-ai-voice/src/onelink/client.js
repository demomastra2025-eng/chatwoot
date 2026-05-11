const { OnelinkApiError, sanitizeErrorMessage } = require('../utils/errors');

class OnelinkClient {
  constructor({
    baseUrl,
    token,
    timeoutMs = 5_000,
    fetchImpl = globalThis.fetch,
    contextPath = '/internal/voice/ai/context',
    transcriptPath = '/internal/voice/ai/transcript',
    controlPath = '/internal/voice/ai/control',
    eventPath = '/internal/voice/ai/event',
    finalizePath = '/internal/voice/ai/finalize'
  } = {}) {
    this.baseUrl = normalizeBaseUrl(
      baseUrl ||
      process.env.VOICE_AGENT_ONELINK_AI_BASE_URL ||
      process.env.ONELINK_INTERNAL_BASE_URL ||
      process.env.CHATWOOT_INTERNAL_BASE_URL ||
      'http://127.0.0.1:3000'
    );
    this.token = token || process.env.VOICE_AGENT_ONELINK_AI_SHARED_SECRET || process.env.ONELINK_AI_VOICE_INTERNAL_TOKEN ||
      process.env.ONELINK_INTERNAL_SECRET || process.env.ONELINK_INTERNAL_TOKEN || process.env.VOICE_AGENT_INTERNAL_TOKEN || '';
    this.timeoutMs = timeoutMs;
    this.fetchImpl = fetchImpl;
    this.paths = {
      context: contextPath,
      transcript: transcriptPath,
      control: controlPath,
      event: eventPath,
      finalize: finalizePath
    };

    if (typeof this.fetchImpl !== 'function') {
      throw new Error('fetch implementation is required');
    }
  }

  getContext(params = {}) {
    return this.request(this.paths.context, { method: 'POST', body: normalizeKeys(params) });
  }

  sendTranscript(payload = {}) {
    return this.request(this.paths.transcript, { method: 'POST', body: normalizeKeys(payload) });
  }

  sendControl(payload = {}) {
    return this.request(this.paths.control, { method: 'POST', body: normalizeKeys(payload) });
  }

  sendEvent(payload = {}) {
    return this.request(this.paths.event, {
      method: 'POST',
      body: normalizeKeys(payload),
      headers: eventHeaders(payload)
    });
  }

  finalizeCall(payload = {}) {
    return this.request(this.paths.finalize, {
      method: 'POST',
      body: normalizeKeys(payload),
      headers: eventHeaders(payload)
    });
  }

  routeInbound(payload = {}) {
    return this.request('/internal/voice/inbound/route', { method: 'POST', body: normalizeKeys(payload) });
  }

  async callTool(name, payload = {}, options = {}) {
    const safeName = encodeURIComponent(String(name || '').trim());
    const response = await this.request(`/internal/voice/ai/tools/${safeName}`, {
      method: 'POST',
      body: normalizeKeys(payload),
      timeoutMs: options.timeoutMs
    });
    return Object.prototype.hasOwnProperty.call(response, 'result') ? response.result : response;
  }

  sendBridgeEvent(payload = {}) {
    return this.request('/internal/voice/inbound/event', { method: 'POST', body: normalizeKeys(payload) });
  }

  async request(path, { method = 'GET', query = null, body = null, headers: extraHeaders = {}, timeoutMs = this.timeoutMs } = {}) {
    const url = new URL(path, `${this.baseUrl}/`);
    if (query && typeof query === 'object') {
      Object.entries(query).forEach(([key, value]) => {
        if (value !== undefined && value !== null && value !== '') {
          url.searchParams.set(key, String(value));
        }
      });
    }

    const controller = new AbortController();
    const timer = timeoutMs > 0 ? setTimeout(() => controller.abort(), timeoutMs) : null;
    const headers = {
      accept: 'application/json',
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...extraHeaders,
      ...(this.token ? { authorization: `Bearer ${this.token}` } : {})
    };

    try {
      const response = await this.fetchImpl(url, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal
      });
      const raw = await response.text();
      const parsed = parseJson(raw);

      if (!response.ok) {
        throw new OnelinkApiError(parsed.message || parsed.error || `HTTP ${response.status}`, {
          status: response.status,
          code: parsed.error || parsed.code || 'http_error',
          details: parsed.details || null
        });
      }

      return parsed;
    } catch (error) {
      if (error.name === 'AbortError') {
        throw new OnelinkApiError(`request timed out after ${timeoutMs}ms`, { status: 0, code: 'timeout' });
      }
      if (error instanceof OnelinkApiError) {
        throw error;
      }
      throw new OnelinkApiError(sanitizeErrorMessage(error.message || 'request failed'), { status: 0, code: error.code || 'request_failed' });
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}

function normalizeBaseUrl(value) {
  return String(value || '').replace(/\/+$/, '');
}

function parseJson(raw) {
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch (_error) {
    return { raw };
  }
}

function normalizeKeys(payload) {
  if (!payload || typeof payload !== 'object') return {};
  return Object.fromEntries(Object.entries(payload).filter(([, value]) => value !== undefined));
}

function eventHeaders(payload = {}) {
  const eventId = payload.event_id || payload.eventId;
  const idempotencyKey = payload.idempotency_key || payload.idempotencyKey || payload.event_key || payload.eventKey || eventId;
  const attempt = payload.attempt || payload.event_attempt || payload.eventAttempt || 1;

  return Object.fromEntries(Object.entries({
    'x-event-id': eventId,
    'x-idempotency-key': idempotencyKey,
    'x-event-attempt': attempt
  }).filter(([, value]) => value !== undefined && value !== null && value !== ''));
}

module.exports = { OnelinkClient, OnelinkApiError };
