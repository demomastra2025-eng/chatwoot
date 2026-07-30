import QRCode from 'qrcode';

const MAX_QR_TOKEN_BYTES = 4096;
const KASPI_QR_HOST = 'qr.kaspi.kz';

export const validateKaspiQrToken = token => {
  const value = String(token || '').trim();
  if (!value) throw new Error('qrToken required');
  if (Buffer.byteLength(value, 'utf8') > MAX_QR_TOKEN_BYTES) throw new Error('qrToken is too long');

  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error('qrToken must be a valid URL');
  }

  if (url.protocol !== 'https:' || url.hostname !== KASPI_QR_HOST) {
    throw new Error('qrToken must be an HTTPS Kaspi Unified QR URL');
  }

  return url.toString();
};

export const renderKaspiQrPng = async token =>
  QRCode.toBuffer(validateKaspiQrToken(token), {
    type: 'png',
    errorCorrectionLevel: 'M',
    margin: 4,
    width: 768,
  });
