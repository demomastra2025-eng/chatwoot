const crypto = require('node:crypto');

const DEFAULT_PATH = '/internal/pipecat/runtime-control';

class PipecatRuntimeControlRegistry {
  constructor({
    baseUrl,
    path = DEFAULT_PATH,
    ttlMs = 300_000,
    transferTimeoutMs = 30_000,
    maxBodyBytes = 16 * 1024
  } = {}) {
    this.baseUrl = String(baseUrl || '').replace(/\/+$/, '');
    this.path = normalizedPath(path);
    this.ttlMs = positiveInteger(ttlMs, 300_000);
    this.transferTimeoutMs = positiveInteger(transferTimeoutMs, 30_000);
    this.maxBodyBytes = positiveInteger(maxBodyBytes, 16 * 1024);
    this.entries = new Map();
  }

  register(call) {
    if (!this.baseUrl) throw controlError('runtime control base URL is not configured', 'runtime_control_unavailable', 503);
    if (!call || typeof call.hangup !== 'function' || typeof call.transfer !== 'function') {
      throw controlError('runtime call control is unavailable', 'runtime_control_unavailable', 503);
    }
    this.prune();
    const id = crypto.randomBytes(18).toString('base64url');
    const token = crypto.randomBytes(32).toString('base64url');
    const entry = {
      call,
      token,
      expiresAt: Date.now() + this.ttlMs,
      ended: false,
      commands: new Map()
    };
    call.once?.('end', () => setImmediate(() => this.release(id)));
    this.entries.set(id, entry);
    return {
      id,
      control_url: `${this.baseUrl}${this.path}/${id}`,
      token
    };
  }

  release(id) {
    if (id) this.entries.delete(String(id));
  }

  handleRequest(req, res) {
    const url = new URL(req.url || '/', 'http://runtime-control.local');
    const prefix = `${this.path}/`;
    if (req.method !== 'POST' || !url.pathname.startsWith(prefix)) return false;
    const id = url.pathname.slice(prefix.length);
    if (!id || id.includes('/')) return false;
    void this.processRequest(id, req, res);
    return true;
  }

  async processRequest(id, req, res) {
    try {
      this.prune();
      const entry = this.entries.get(id);
      if (!entry || !authorized(req.headers?.authorization, entry.token)) {
        writeJson(res, 401, { error: 'unauthorized' });
        return;
      }
      const payload = await readJson(req, this.maxBodyBytes);
      const action = String(payload.action || '').trim().toLowerCase();
      if (!['transfer', 'end_call'].includes(action)) {
        writeJson(res, 422, { error: 'unsupported_runtime_action' });
        return;
      }
      const result = await this.execute(entry, action, payload);
      writeJson(res, 200, result);
    } catch (error) {
      writeJson(res, error.statusCode || 502, {
        error: error.code || 'runtime_control_failed',
        message: String(error.message || 'runtime control failed').slice(0, 200)
      });
    }
  }

  async execute(entry, action, payload) {
    const fingerprint = actionFingerprint(action, payload);
    const existing = entry.commands.get(action);
    if (existing) {
      if (existing.fingerprint !== fingerprint) {
        throw controlError('conflicting runtime action', 'runtime_action_conflict', 409);
      }
      return existing.execution;
    }
    if (entry.ended && action !== 'end_call') {
      throw controlError('call already ended', 'runtime_call_ended', 409);
    }
    const execution = (async () => {
      if (action === 'transfer') {
        const destination = String(payload.operator_agent_aor || '').trim();
        if (!destination) throw controlError('operator_agent_aor is required', 'transfer_destination_required', 422);
        const transferLeg = await entry.call.transfer({ agent_aor: destination, reason: payload.reason });
        if (transferLeg === false) throw controlError('call transfer was rejected', 'runtime_transfer_rejected', 409);
        const outcome = await waitForTransferOutcome(transferLeg, this.transferTimeoutMs);
        return { status: 'completed', action: 'transfer', outcome };
      }
      await entry.call.hangup();
      return { status: 'accepted', action: 'end_call' };
    })();
    entry.commands.set(action, { fingerprint, execution });
    try {
      const result = await execution;
      entry.expiresAt = Date.now() + this.ttlMs;
      return result;
    } catch (error) {
      entry.expiresAt = Date.now() + this.ttlMs;
      throw error;
    }
  }

  prune(now = Date.now()) {
    for (const [id, entry] of this.entries.entries()) {
      if (entry.expiresAt <= now) this.entries.delete(id);
    }
  }
}

function authorized(header, token) {
  const match = String(header || '').match(/^Bearer\s+(\S+)$/i);
  if (!match) return false;
  const provided = match[1];
  const expected = Buffer.from(String(token || ''));
  const actual = Buffer.from(provided);
  return expected.length > 0 && expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

function actionFingerprint(action, payload) {
  const normalized = action === 'transfer'
    ? {
        action,
        operator_agent_aor: String(payload.operator_agent_aor || '').trim(),
        reason: String(payload.reason || '').trim()
      }
    : { action, reason: String(payload.reason || '').trim() };
  return crypto.createHash('sha256').update(JSON.stringify(normalized)).digest('hex');
}

function waitForTransferOutcome(leg, timeoutMs) {
  if (!leg || typeof leg.once !== 'function' || typeof leg.removeListener !== 'function') {
    throw controlError('transfer leg lifecycle is unavailable', 'runtime_transfer_lifecycle_unavailable', 502);
  }
  const bufferedOutcome = transferOutcomeResult(leg.terminalOutcome);
  if (bufferedOutcome) {
    if (bufferedOutcome.error) throw bufferedOutcome.error;
    return Promise.resolve(bufferedOutcome.outcome);
  }
  return new Promise((resolve, reject) => {
    let timer;
    const cleanup = () => {
      clearTimeout(timer);
      for (const [event, handler] of Object.entries(handlers)) leg.removeListener(event, handler);
    };
    const finish = (error, outcome) => {
      cleanup();
      if (error) reject(error);
      else resolve(outcome);
    };
    const handlers = {
      answered: () => finish(null, 'answered'),
      busy: () => finish(controlError('transfer target is busy', 'runtime_transfer_busy', 409)),
      no_answer: () => finish(controlError('transfer target did not answer', 'runtime_transfer_no_answer', 504)),
      failed: () => finish(controlError('call transfer failed', 'runtime_transfer_failed', 502)),
      end: () => finish(controlError('call ended before transfer completed', 'runtime_transfer_ended', 409))
    };
    for (const [event, handler] of Object.entries(handlers)) leg.once(event, handler);
    timer = setTimeout(() => {
      finish(controlError('call transfer timed out', 'runtime_transfer_timeout', 504));
    }, timeoutMs);
  });
}

function transferOutcomeResult(outcome) {
  if (outcome === 'answered') return { outcome: 'answered' };
  if (outcome === 'busy') return { error: controlError('transfer target is busy', 'runtime_transfer_busy', 409) };
  if (outcome === 'no_answer') return { error: controlError('transfer target did not answer', 'runtime_transfer_no_answer', 504) };
  if (outcome === 'failed') return { error: controlError('call transfer failed', 'runtime_transfer_failed', 502) };
  if (outcome === 'end') return { error: controlError('call ended before transfer completed', 'runtime_transfer_ended', 409) };
  return null;
}

async function readJson(req, maxBodyBytes) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBodyBytes) throw controlError('request body is too large', 'payload_too_large', 413);
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
  } catch (_error) {
    throw controlError('invalid JSON body', 'invalid_json', 400);
  }
}

function writeJson(res, statusCode, payload) {
  if (res.writableEnded) return;
  res.statusCode = statusCode;
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify(payload));
}

function controlError(message, code, statusCode) {
  const error = new Error(message);
  error.code = code;
  error.statusCode = statusCode;
  return error;
}

function normalizedPath(value) {
  const path = String(value || DEFAULT_PATH).trim();
  return `/${path.replace(/^\/+|\/+$/g, '')}`;
}

function positiveInteger(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

module.exports = { PipecatRuntimeControlRegistry };
