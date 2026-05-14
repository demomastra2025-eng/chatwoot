const PAYMENT_PROVIDER_CONFIGS = {
  kaspi_pay: {
    id: 'kaspi_pay',
    name: 'Kaspi Pay',
    supports: ['qr_link'],
  },
};

const enabledHookStatuses = [true, 'enabled'];

const hasEnabledHook = integration =>
  integration.hooks?.some(hook => enabledHookStatuses.includes(hook.status));

export const getEnabledPaymentProviders = (appIntegrations = []) =>
  appIntegrations
    .filter(integration => PAYMENT_PROVIDER_CONFIGS[integration.id])
    .filter(hasEnabledHook)
    .map(integration => ({
      ...PAYMENT_PROVIDER_CONFIGS[integration.id],
      integration,
    }));

export const hasEnabledPaymentProvider = appIntegrations =>
  getEnabledPaymentProviders(appIntegrations).length > 0;

export const isKaspiPayEnabled = appIntegrations =>
  getEnabledPaymentProviders(appIntegrations).some(
    provider => provider.id === 'kaspi_pay'
  );
