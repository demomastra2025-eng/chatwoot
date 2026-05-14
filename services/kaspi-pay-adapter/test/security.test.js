import assert from 'node:assert/strict';
import test from 'node:test';
import { requireInternalSignature, signPayload } from '../src/security.js';

const withEnv = async (value, fn) => {
  const old = process.env.KASPI_PAY_INTERNAL_SECRET;
  if (value == null) delete process.env.KASPI_PAY_INTERNAL_SECRET;
  else process.env.KASPI_PAY_INTERNAL_SECRET = value;

  try {
    await fn();
  } finally {
    if (old == null) delete process.env.KASPI_PAY_INTERNAL_SECRET;
    else process.env.KASPI_PAY_INTERNAL_SECRET = old;
  }
};

const reqFor = ({
  timestamp,
  signature,
  rawBody = '{"amount":15000}',
  method = 'POST',
  originalUrl = '/internal/kaspi/qr/create',
}) => ({
  method,
  originalUrl,
  rawBody,
  get: name => ({
    'X-OneLink-Timestamp': timestamp,
    'X-OneLink-Internal-Signature': signature,
  })[name],
});

const resStub = () => {
  const res = {
    statusCode: 200,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(payload) {
      this.body = payload;
      return this;
    },
  };
  return res;
};

test('signPayload binds method, path, timestamp, and raw body with HMAC-SHA256', () => {
  assert.equal(
    signPayload({
      secret: 'secret',
      method: 'POST',
      path: '/internal/kaspi/qr/create',
      timestamp: '1700000000',
      rawBody: '{"ok":true}',
    }),
    'a72350645df0869a7e17ac3961b56428444ae8223493cbb9b6196ffae84e2eb2'
  );
});

test('requireInternalSignature accepts a fresh valid signature', async () => {
  await withEnv('internal-secret', () => {
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const rawBody = '{"amount":15000}';
    const signature = signPayload({ secret: 'internal-secret', method: 'POST', path: '/internal/kaspi/qr/create', timestamp, rawBody });
    const req = reqFor({ timestamp, signature, rawBody });
    const res = resStub();
    let called = false;

    requireInternalSignature(req, res, () => {
      called = true;
    });

    assert.equal(called, true);
    assert.equal(res.body, null);
  });
});

test('requireInternalSignature rejects invalid signatures', async () => {
  await withEnv('internal-secret', () => {
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const req = reqFor({ timestamp, signature: '00', rawBody: '{"amount":15000}' });
    const res = resStub();

    requireInternalSignature(req, res, () => assert.fail('next should not be called'));

    assert.equal(res.statusCode, 401);
    assert.deepEqual(res.body, { error: 'Invalid internal signature' });
  });
});

test('requireInternalSignature rejects expired timestamps', async () => {
  await withEnv('internal-secret', () => {
    const timestamp = Math.floor(Date.now() / 1000 - 600).toString();
    const rawBody = '{"amount":15000}';
    const signature = signPayload({ secret: 'internal-secret', method: 'POST', path: '/internal/kaspi/qr/create', timestamp, rawBody });
    const req = reqFor({ timestamp, signature, rawBody });
    const res = resStub();

    requireInternalSignature(req, res, () => assert.fail('next should not be called'));

    assert.equal(res.statusCode, 401);
    assert.deepEqual(res.body, { error: 'Expired internal signature' });
  });
});

test('requireInternalSignature rejects replay against a different query string', async () => {
  await withEnv('internal-secret', () => {
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const signature = signPayload({
      secret: 'internal-secret',
      method: 'GET',
      path: '/internal/kaspi/qr/status?qrOperationId=qr-1',
      timestamp,
      rawBody: '',
    });
    const req = reqFor({
      timestamp,
      signature,
      rawBody: '',
      method: 'GET',
      originalUrl: '/internal/kaspi/qr/status?qrOperationId=qr-2',
    });
    const res = resStub();

    requireInternalSignature(req, res, () => assert.fail('next should not be called'));

    assert.equal(res.statusCode, 401);
    assert.deepEqual(res.body, { error: 'Invalid internal signature' });
  });
});

test('requireInternalSignature reports missing adapter secret', async () => {
  await withEnv(null, () => {
    const req = reqFor({ timestamp: Math.floor(Date.now() / 1000).toString(), signature: '00' });
    const res = resStub();

    requireInternalSignature(req, res, () => assert.fail('next should not be called'));

    assert.equal(res.statusCode, 503);
    assert.deepEqual(res.body, { error: 'Adapter secret is not configured' });
  });
});
