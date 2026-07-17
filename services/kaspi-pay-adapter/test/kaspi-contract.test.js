import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { normalizeQrResponse } from '../src/qr-response.js';

process.env.TOKEN_SECRET_KEY ||= '00'.repeat(32);
const { buildXSignPayload } = await import('../src/crypto.js');

const headers = {
  'X-Install-ID': 'install-id',
  'X-PI': '123',
  'X-App-Bld': '1070',
  'X-Platform-Ver': '18.5',
  'X-Locale': 'ru-RU',
  'X-App-Ver': '4.105',
  'X-Device-ID': 'device-id',
  'X-SV': '2',
  'X-Time': '2026-07-17T10:00:00.000+0000',
  'X-Platform-Type': 'iOS',
  'X-Call': 'notConnected',
  'X-Kb-TokenSnMac': '123456',
  'X-Kb-TokenSn': 'token-sn',
};
const xsh =
  'url,X-Install-ID,X-PI,X-App-Bld,X-Platform-Ver,X-Locale,X-App-Ver,X-Device-ID,X-SV,X-Time,X-Platform-Type,X-Call,X-Kb-TokenSnMac,X-Kb-TokenSn';

test('X-Sign payload includes the full URL, newline-delimited headers, and raw body', () => {
  const body = '{"PaymentAmount":15000,"DeviceInterface":"Pos"}';
  assert.equal(
    buildXSignPayload('https://qrpay.kaspi.kz/v01/qr-token/create', headers, xsh, body),
    'url:https://qrpay.kaspi.kz/v01/qr-token/create\n' +
      'x-install-id:install-id\n' +
      'x-pi:123\n' +
      'x-app-bld:1070\n' +
      'x-platform-ver:18.5\n' +
      'x-locale:ru-RU\n' +
      'x-app-ver:4.105\n' +
      'x-device-id:device-id\n' +
      'x-sv:2\n' +
      'x-time:2026-07-17T10:00:00.000+0000\n' +
      'x-platform-type:iOS\n' +
      'x-call:notConnected\n' +
      'x-kb-tokensnmac:123456\n' +
      'x-kb-tokensn:token-sn\n' +
      body
  );
});

test('auth POST callers sign the exact serialized request body', () => {
  const authSource = fs.readFileSync(new URL('../src/routes/auth.js', import.meta.url), 'utf8');

  assert.match(authSource, /computeXSign\(finishUrl, finishHeaders, finishHeaders\['X-SH'\], finishBody\)/);
  assert.equal((authSource.match(/computeXSign\(orgUrl, orgHeaders, orgHeaders\['X-SH'\], orgBody\)/g) || []).length, 2);
  assert.match(authSource, /computeXSign\(liteUrl, liteHeaders, liteHeaders\['X-SH'\], liteBody\)/);
});

test('QR response preserves the original Unified QR token', () => {
  const response = normalizeQrResponse({ Data: { QrToken: 'https://qr.kaspi.kz/original-token' } });

  assert.equal(response.Data.QrOriginalToken, 'https://qr.kaspi.kz/original-token');
  assert.equal(response.Data.QrToken, 'https://pay.kaspi.kz/pay/original-token');
});

test('QR response does not overwrite a provider-supplied original token', () => {
  const response = normalizeQrResponse({
    Data: {
      QrToken: 'https://qr.kaspi.kz/rewritten-token',
      QrOriginalToken: 'https://qr.kaspi.kz/provider-original',
    },
  });

  assert.equal(response.Data.QrOriginalToken, 'https://qr.kaspi.kz/provider-original');
  assert.equal(response.Data.QrToken, 'https://pay.kaspi.kz/pay/rewritten-token');
});
