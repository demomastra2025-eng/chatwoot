class OnelinkApiError extends Error {
  constructor(message, { status = 0, code = 'onelink_api_error', details = null } = {}) {
    super(sanitizeErrorMessage(message || code));
    this.name = 'OnelinkApiError';
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

function sanitizeErrorMessage(value) {
  return String(value || '')
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer [REDACTED]')
    .replace(/token[=:]\s*[A-Za-z0-9._~+/=-]+/gi, 'token=[REDACTED]')
    .slice(0, 1000);
}

module.exports = { OnelinkApiError, sanitizeErrorMessage };
