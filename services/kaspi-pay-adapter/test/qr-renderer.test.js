import assert from 'node:assert/strict';
import test from 'node:test';
import { renderKaspiQrPng, validateKaspiQrToken } from '../src/qr-renderer.js';

test('renders an original Kaspi Unified QR URL as a PNG', async () => {
  const png = await renderKaspiQrPng('https://qr.kaspi.kz/example-token');

  assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.ok(png.length > 1_000);
  assert.ok(png.length < 1_000_000);
});

test('rejects non-Kaspi and non-HTTPS QR content', () => {
  assert.throws(() => validateKaspiQrToken('https://example.com/payment'), /Kaspi Unified QR/);
  assert.throws(() => validateKaspiQrToken('http://qr.kaspi.kz/payment'), /Kaspi Unified QR/);
  assert.throws(() => validateKaspiQrToken('not-a-url'), /valid URL/);
});
