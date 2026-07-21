class PipecatAttachClient {
  constructor({ baseUrl = '', token = '', timeoutMs = 5_000, fetchImpl = globalThis.fetch } = {}) {
    this.baseUrl = String(baseUrl || '').replace(/\/+$/, '');
    this.token = String(token || '').trim();
    this.timeoutMs = Math.max(100, Number(timeoutMs) || 5_000);
    this.fetchImpl = fetchImpl;
  }

  async attachJanus(payload) {
    return this.#attach('/internal/janus-sip/calls', payload);
  }

  async preflightJanus(payload) {
    return this.#request('/internal/janus-sip/preflight', payload, {
      failureCode: 'pipecat_preflight_failed',
      failureStatusCode: 503
    });
  }

  async attachWhatsapp(payload) {
    return this.#attach('/internal/whatsapp-cloud/calls', payload);
  }

  async preflightWhatsapp(payload) {
    return this.#request('/internal/whatsapp-cloud/preflight', payload, {
      failureCode: 'pipecat_preflight_failed',
      failureStatusCode: 503
    });
  }

  isAvailable() {
    return Boolean(this.baseUrl && this.token && typeof this.fetchImpl === 'function');
  }

  async ensureAvailable() {
    if (!this.isAvailable()) {
      throw attachError('Pipecat runtime is not configured', 'pipecat_runtime_unavailable', 503);
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchImpl(`${this.baseUrl}/ready`, {
        method: 'GET',
        headers: { authorization: ['Bearer', this.token].join(' ') },
        signal: controller.signal
      });
      if (!response.ok) {
        throw attachError(
          `Pipecat runtime readiness failed with status ${response.status}`,
          'pipecat_runtime_unavailable',
          503
        );
      }
      return true;
    } catch (error) {
      if (error?.code === 'pipecat_runtime_unavailable') throw error;
      throw attachError('Pipecat runtime readiness request failed', 'pipecat_runtime_unavailable', 503);
    } finally {
      clearTimeout(timer);
    }
  }

  async #attach(path, payload) {
    return this.#request(path, payload, {
      failureCode: 'pipecat_attach_failed',
      failureStatusCode: 502
    });
  }

  async #request(path, payload, { failureCode, failureStatusCode }) {
    if (!this.isAvailable()) {
      throw attachError('Pipecat runtime is not configured', 'pipecat_runtime_unavailable', 503);
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    timer.unref?.();
    try {
      const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method: 'POST',
        headers: {
          authorization: ['Bearer', this.token].join(' '),
          'content-type': 'application/json'
        },
        body: JSON.stringify(payload || {}),
        signal: controller.signal
      });
      if (!response.ok) {
        throw attachError(
          `Pipecat request failed with status ${response.status}`,
          failureCode,
          failureStatusCode
        );
      }
      return await response.json();
    } catch (error) {
      if (error?.code) throw error;
      const code = error?.name === 'AbortError' ? `${failureCode}_timeout` : failureCode;
      throw attachError('Pipecat request failed', code, failureStatusCode);
    } finally {
      clearTimeout(timer);
    }
  }
}

function attachError(message, code, statusCode) {
  const error = new Error(message);
  error.code = code;
  error.statusCode = statusCode;
  return error;
}

module.exports = { PipecatAttachClient };
