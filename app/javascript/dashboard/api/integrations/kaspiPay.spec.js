import KaspiPayAPI from './kaspiPay';

describe('KaspiPayAPI', () => {
  beforeEach(() => {
    window.axios = {
      get: vi.fn().mockResolvedValue({ data: {} }),
      post: vi.fn().mockResolvedValue({ data: {} }),
      patch: vi.fn().mockResolvedValue({ data: {} }),
      delete: vi.fn().mockResolvedValue({ data: {} }),
    };
    Object.defineProperty(window, 'location', {
      value: { pathname: '/app/accounts/42/settings/integrations/kaspi_pay' },
      writable: true,
    });
  });

  it('calls account-scoped onboarding and session endpoints', async () => {
    await KaspiPayAPI.getStatus({ verify: true });
    expect(window.axios.get).toHaveBeenCalledWith(
      '/api/v1/accounts/42/integrations/kaspi_pay/status',
      { params: { verify: true } }
    );

    await KaspiPayAPI.sendOtp({ phoneNumber: '+7 701 111 22 33' });
    expect(window.axios.post).toHaveBeenCalledWith(
      '/api/v1/accounts/42/integrations/kaspi_pay/send_otp',
      {
        phone_number: '+7 701 111 22 33',
        app_version: undefined,
        app_build: undefined,
      }
    );

    await KaspiPayAPI.verifyOtp({ processId: 'pid_1', otp: '1234' });
    expect(window.axios.post).toHaveBeenCalledWith(
      '/api/v1/accounts/42/integrations/kaspi_pay/verify_otp',
      { process_id: 'pid_1', otp: '1234' }
    );
  });

  it('calls account-scoped payment lifecycle endpoints', async () => {
    await KaspiPayAPI.createPayment({ payment_type: 'qr', amount: 15000 });
    expect(window.axios.post).toHaveBeenCalledWith(
      '/api/v1/accounts/42/kaspi_pay/payments',
      { payment_type: 'qr', amount: 15000 }
    );

    await KaspiPayAPI.refreshPayment(99);
    expect(window.axios.post).toHaveBeenCalledWith(
      '/api/v1/accounts/42/kaspi_pay/payments/99/refresh'
    );

    await KaspiPayAPI.cancelPayment(99);
    expect(window.axios.post).toHaveBeenCalledWith(
      '/api/v1/accounts/42/kaspi_pay/payments/99/cancel'
    );

    await KaspiPayAPI.refundPayment(99, { amount: 5000 });
    expect(window.axios.post).toHaveBeenCalledWith(
      '/api/v1/accounts/42/kaspi_pay/payments/99/refund',
      { amount: 5000 }
    );

    await KaspiPayAPI.getClientInfo('+77012223344', { conversationId: 12 });
    expect(window.axios.post).toHaveBeenCalledWith(
      '/api/v1/accounts/42/kaspi_pay/payments/client_info',
      { phone_number: '+77012223344', conversation_id: 12 }
    );
  });
});
