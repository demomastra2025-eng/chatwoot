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

router.get('/client-info', async (req, res) => {
  const { phoneNumber } = req.query;
  if (!phoneNumber) return res.status(400).json({ error: 'phoneNumber required' });

  try {
    const url = `${KASPI_QRPAY_URL}/v01/remote/client-info?phoneNumber=${encodeURIComponent(phoneNumber)}`;
    const resp = await loggedFetch(url, { headers: signedQrPayHeaders(url, req.session) });
    res.status(resp.ok ? 200 : resp.status).json(await resp.json());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

router.post('/create', async (req, res) => {
  const { phoneNumber, amount, comment } = req.body;
  if (!phoneNumber || !amount) return res.status(400).json({ error: 'phoneNumber and amount required' });

  try {
    const url = `${KASPI_QRPAY_URL}/v01/remote/create`;
    const body = JSON.stringify({ PhoneNumber: phoneNumber, Amount: Number(amount), Comment: comment || '' });
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

router.get('/details', async (req, res) => {
  const { operationId } = req.query;
  if (!operationId) return res.status(400).json({ error: 'operationId required' });

  try {
    const url = `${KASPI_QRPAY_URL}/v02/remote/details?operationId=${encodeURIComponent(operationId)}`;
    const resp = await loggedFetch(url, { headers: signedQrPayHeaders(url, req.session) });
    res.status(resp.ok ? 200 : resp.status).json(await resp.json());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

router.post('/cancel', async (req, res) => {
  const { operationId } = req.body;
  if (!operationId) return res.status(400).json({ error: 'operationId required' });

  try {
    const url = `${KASPI_QRPAY_URL}/v01/remote/cancel`;
    const body = JSON.stringify({ qrOperationId: Number(operationId) });
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

router.post('/history', async (_req, res) => {
  try {
    const url = `${KASPI_QRPAY_URL}/v01/remote/history`;
    const body = JSON.stringify({ MaxResult: 20 });
    const headers = { ...signedQrPayHeaders(url, _req.session, body), 'Content-Type': 'application/json' };
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
