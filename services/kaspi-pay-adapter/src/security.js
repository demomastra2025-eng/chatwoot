import crypto from 'node:crypto';

const MAX_CLOCK_SKEW_SECONDS = 300;

const timingSafeEqual = (left, right) => {
  const a = Buffer.from(left || '', 'hex');
  const b = Buffer.from(right || '', 'hex');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
};

export const signPayload = ({ secret, method, path, timestamp, rawBody }) =>
  crypto
    .createHmac('sha256', secret)
    .update([method.toUpperCase(), path, timestamp, rawBody || ''].join('\n'))
    .digest('hex');

export const requireInternalSignature = (req, res, next) => {
  const secret = process.env.KASPI_PAY_INTERNAL_SECRET;
  if (!secret) return res.status(503).json({ error: 'Adapter secret is not configured' });

  const timestamp = req.get('X-OneLink-Timestamp');
  const signature = req.get('X-OneLink-Internal-Signature');
  if (!timestamp || !signature) return res.status(401).json({ error: 'Missing internal signature' });

  const ageSeconds = Math.abs(Date.now() / 1000 - Number(timestamp));
  if (!Number.isFinite(ageSeconds) || ageSeconds > MAX_CLOCK_SKEW_SECONDS) {
    return res.status(401).json({ error: 'Expired internal signature' });
  }

  const expected = signPayload({
    secret,
    method: req.method,
    path: req.originalUrl || req.url,
    timestamp,
    rawBody: req.rawBody,
  });
  if (!timingSafeEqual(expected, signature)) return res.status(401).json({ error: 'Invalid internal signature' });

  return next();
};
