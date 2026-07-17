import { Router } from 'express';
import { KASPI_QRPAY_URL } from '../config.js';
import { loggedFetch, signedQrPayHeaders } from '../helpers.js';
import { decryptSecret } from '../crypto.js';
import { normalizeQrResponse } from '../qr-response.js';

const router = Router();

// Extract session from request headers
const extractSession = (req) => ({
  tokenSN: req.headers['x-token-sn'] || null,
  profileId: req.headers['x-profile-id'] || null,
  vtokenSecret: req.headers['x-vtoken-secret'] || null,
});

const requireAuth = (req, res, next) => {
  const session = extractSession(req);
  if (!session.tokenSN) return res.status(401).json({ error: 'Missing X-Token-SN header.' });
  if (!session.vtokenSecret) return res.status(401).json({ error: 'Missing X-Vtoken-Secret header.' });
  try {
    session.decryptedSecret = decryptSecret(session.vtokenSecret);
  } catch {
    return res.status(401).json({ error: 'Invalid or expired vtokenSecret. Re-authenticate.' });
  }
  req.session = session;
  next();
};

router.use(requireAuth);

// ─── Create QR token ───

router.post('/create', async (req, res) => {
  const { amount, latitude, longitude } = req.body;
  if (!amount) return res.status(400).json({ error: 'amount required' });

  try {
    const url = `${KASPI_QRPAY_URL}/v01/qr-token/create`;
    const body = JSON.stringify({
      PaymentAmount: Number(amount),
      DeviceInterface: 'Pos',
      Latitude: latitude || 43.204643483375889,
      Longitude: longitude || 76.891962364115912,
    });
    const headers = { ...signedQrPayHeaders(url, req.session, body), 'Content-Type': 'application/json' };
    const resp = await loggedFetch(url, {
      method: 'POST',
      headers,
      body,
    });
    const kaspiResponse = await resp.json();
    res.status(resp.ok ? 200 : resp.status).json(normalizeQrResponse(kaspiResponse));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ─── QR payment status ───

router.get('/status', async (req, res) => {
  const { qrOperationId } = req.query;
  if (!qrOperationId) return res.status(400).json({ error: 'qrOperationId required' });

  try {
    const url = `${KASPI_QRPAY_URL}/v02/kaspi-qr/status?qrOperationId=${qrOperationId}`;
    const resp = await loggedFetch(url, { headers: signedQrPayHeaders(url, req.session) });
    res.status(resp.ok ? 200 : resp.status).json(await resp.json());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
