import { Router } from 'express';
import { KASPI_QRPAY_URL } from '../config.js';
import { loggedFetch, signedQrPayHeaders } from '../helpers.js';
import { decryptSecret } from '../crypto.js';

const router = Router();

const extractSession = req => ({
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
  return next();
};

router.use(requireAuth);

router.post('/create', async (req, res) => {
  const { qrOperationId, returnAmount } = req.body;
  if (!qrOperationId || !returnAmount) return res.status(400).json({ error: 'qrOperationId and returnAmount required' });
  const numericQrOperationId = Number(qrOperationId);
  const numericReturnAmount = Number(returnAmount);
  if (!Number.isFinite(numericQrOperationId) || !Number.isFinite(numericReturnAmount) || numericReturnAmount <= 0) {
    return res.status(400).json({ error: 'numeric qrOperationId and positive returnAmount required' });
  }

  try {
    const url = `${KASPI_QRPAY_URL}/v01/kaspi-qr/history-pos-return`;
    const body = JSON.stringify({ ReturnAmount: numericReturnAmount, QrOperationId: numericQrOperationId, DeviceInterface: 'Pos' });
    const headers = { ...signedQrPayHeaders(url, req.session, body), 'Content-Type': 'application/json' };
    const resp = await loggedFetch(url, {
      method: 'POST',
      headers,
      body,
    });
    res.status(resp.ok ? 200 : resp.status).json(await resp.json());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
