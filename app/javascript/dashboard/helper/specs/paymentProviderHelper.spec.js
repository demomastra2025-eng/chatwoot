import {
  getEnabledPaymentProviders,
  hasEnabledPaymentProvider,
  isKaspiPayEnabled,
} from '../paymentProviderHelper';

describe('paymentProviderHelper', () => {
  it('does not expose payments when Kaspi Pay is not connected', () => {
    const integrations = [
      { id: 'kaspi_pay', hooks: [] },
      { id: 'slack', hooks: [{ status: true }] },
    ];

    expect(getEnabledPaymentProviders(integrations)).toEqual([]);
    expect(hasEnabledPaymentProvider(integrations)).toBe(false);
    expect(isKaspiPayEnabled(integrations)).toBe(false);
  });

  it('exposes Kaspi Pay only when an enabled hook exists', () => {
    const integrations = [
      { id: 'kaspi_pay', hooks: [{ id: 1, status: false }] },
      { id: 'kaspi_pay', hooks: [{ id: 2, status: 'disabled' }] },
      { id: 'kaspi_pay', hooks: [{ id: 3, status: 'enabled' }] },
    ];

    expect(getEnabledPaymentProviders(integrations)).toEqual([
      expect.objectContaining({ id: 'kaspi_pay', name: 'Kaspi Pay' }),
    ]);
    expect(hasEnabledPaymentProvider(integrations)).toBe(true);
    expect(isKaspiPayEnabled(integrations)).toBe(true);
  });
});
