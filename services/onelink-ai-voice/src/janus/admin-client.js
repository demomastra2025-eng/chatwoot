const crypto = require('node:crypto');

const DEFAULT_PLUGIN = 'janus.plugin.sip';

class JanusAdminError extends Error {
  constructor(message, { statusCode = null, response = null } = {}) {
    super(message);
    this.name = 'JanusAdminError';
    this.statusCode = statusCode;
    this.response = response;
  }
}

class JanusAdminClient {
  constructor({
    baseUrl,
    adminSecret = '',
    fetchImpl = globalThis.fetch,
    plugin = DEFAULT_PLUGIN,
    transactionPrefix = 'onelink-ai'
  } = {}) {
    this.baseUrl = normalizeAdminBaseUrl(baseUrl);
    this.adminSecret = adminSecret;
    this.fetchImpl = fetchImpl;
    this.plugin = plugin || DEFAULT_PLUGIN;
    this.transactionPrefix = transactionPrefix || 'onelink-ai';
  }

  async messagePlugin({ request, sessionId = null, handleId = null, plugin = this.plugin, addressHandle = false } = {}) {
    if (!this.baseUrl) throw new JanusAdminError('janus admin baseUrl is required');
    if (typeof this.fetchImpl !== 'function') throw new JanusAdminError('fetch implementation is required');
    if (!request || typeof request !== 'object') throw new JanusAdminError('janus plugin request is required');

    const body = {
      janus: 'message_plugin',
      transaction: this.transactionId(),
      plugin,
      request
    };
    if (this.adminSecret) body.admin_secret = this.adminSecret;
    if (addressHandle && sessionId !== null && sessionId !== undefined && sessionId !== '') body.session_id = numericOrString(sessionId);
    if (addressHandle && handleId !== null && handleId !== undefined && handleId !== '') body.handle_id = numericOrString(handleId);

    const response = await this.fetchImpl(addressHandle ? this.adminUrl({ sessionId, handleId }) : this.baseUrl, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    });
    const payload = await parseJsonResponse(response);

    if (!response.ok) {
      throw new JanusAdminError(`janus admin request failed with HTTP ${response.status}`, {
        statusCode: response.status,
        response: payload
      });
    }
    if (payload?.janus === 'error' || payload?.error) {
      const reason = payload?.error?.reason || payload?.error || 'janus admin error';
      throw new JanusAdminError(String(reason), { statusCode: response.status, response: payload });
    }

    return payload?.response || payload;
  }

  adminUrl({ sessionId = null, handleId = null } = {}) {
    let url = this.baseUrl;
    if (sessionId !== null && sessionId !== undefined && sessionId !== '') url += `/${encodeURIComponent(String(sessionId))}`;
    if (handleId !== null && handleId !== undefined && handleId !== '') url += `/${encodeURIComponent(String(handleId))}`;
    return url;
  }

  transactionId() {
    return `${this.transactionPrefix}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
  }
}

async function parseJsonResponse(response) {
  const text = await response.text();
  if (!text.trim()) return {};
  try {
    return JSON.parse(text);
  } catch (_error) {
    throw new JanusAdminError('janus admin returned invalid JSON', {
      statusCode: response.status,
      response: text.slice(0, 500)
    });
  }
}

function normalizeAdminBaseUrl(baseUrl = '') {
  const value = String(baseUrl || '').trim().replace(/\/+$/, '');
  if (!value) return '';
  return value.endsWith('/admin') ? value : `${value}/admin`;
}

function numericOrString(value) {
  const text = String(value);
  return /^\d+$/.test(text) ? Number(text) : value;
}

module.exports = {
  DEFAULT_PLUGIN,
  JanusAdminClient,
  JanusAdminError,
  normalizeAdminBaseUrl
};
