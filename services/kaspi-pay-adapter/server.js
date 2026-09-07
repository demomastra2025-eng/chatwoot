import 'dotenv/config';
import express from 'express';
import { requireInternalSignature } from './src/security.js';
import authRouter from './src/routes/auth.js';
import qrRouter from './src/routes/qr.js';
import invoiceRouter from './src/routes/invoice.js';
import historyRouter from './src/routes/history.js';
import refundRouter from './src/routes/refund.js';

const app = express();
const port = Number(process.env.PORT || 4077);

app.use(
  express.json({
    limit: '256kb',
    verify: (req, _res, buf) => {
      req.rawBody = buf.toString('utf8');
    },
  })
);

app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    service: 'kaspi-pay-adapter',
    capabilities: ['password-auth-v1', 'account-bound-auth-v1'],
  });
});

app.use('/internal/kaspi', requireInternalSignature);
app.use('/internal/kaspi/auth', authRouter);
app.use('/internal/kaspi/qr', qrRouter);
app.use('/internal/kaspi/invoice', invoiceRouter);
app.use('/internal/kaspi/history', historyRouter);
app.use('/internal/kaspi/refund', refundRouter);

app.use((err, _req, res, _next) => {
  res.status(err.status || 500).json({ error: err.publicMessage || 'Kaspi adapter error' });
});

app.listen(port, '0.0.0.0', () => {
  console.log(`Kaspi Pay adapter listening on ${port}`);
});
