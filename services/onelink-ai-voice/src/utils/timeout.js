const { sanitizeErrorMessage } = require('./errors');

function withTimeout(promise, timeoutMs, label = 'operation') {
  if (!timeoutMs || timeoutMs <= 0) {
    return Promise.resolve(promise);
  }

  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const error = new Error(`${label} timed out after ${timeoutMs}ms`);
      error.code = 'timeout';
      reject(error);
    }, timeoutMs);
  });

  return Promise.race([Promise.resolve(promise), timeout]).finally(() => clearTimeout(timer));
}

function safeReason(error, fallback = 'unknown_error') {
  if (!error) return fallback;
  return sanitizeErrorMessage(error.code || error.message || fallback);
}

module.exports = { withTimeout, safeReason };
