import { useConfig } from '../useConfig';

describe('useConfig', () => {
  const originalChatwootConfig = window.chatwootConfig;
  const originalOneLinkConfig = window.onelinkConfig;

  beforeEach(() => {
    window.onelinkConfig = undefined;
    window.chatwootConfig = {
      hostURL: 'https://example.com',
      vapidPublicKey: 'vapid-key',
      enabledLanguages: ['en', 'fr'],
      isEnterprise: 'true',
      enterprisePlanName: 'enterprise',
    };
  });

  afterEach(() => {
    window.chatwootConfig = originalChatwootConfig;
    window.onelinkConfig = originalOneLinkConfig;
  });

  it('returns the correct configuration values', () => {
    const config = useConfig();

    expect(config.hostURL).toBe('https://example.com');
    expect(config.vapidPublicKey).toBe('vapid-key');
    expect(config.enabledLanguages).toEqual(['en', 'fr']);
    expect(config.isEnterprise).toBe(true);
    expect(config.enterprisePlanName).toBe('enterprise');
  });

  it('prefers canonical OneLink configuration while retaining the legacy fallback', () => {
    window.onelinkConfig = { hostURL: 'https://canonical.example.test' };
    expect(useConfig().hostURL).toBe('https://canonical.example.test');
  });

  it('handles missing configuration values', () => {
    window.chatwootConfig = {};
    const config = useConfig();

    expect(config.hostURL).toBeUndefined();
    expect(config.vapidPublicKey).toBeUndefined();
    expect(config.enabledLanguages).toBeUndefined();
    expect(config.isEnterprise).toBe(false);
    expect(config.enterprisePlanName).toBeUndefined();
  });

  it('handles undefined window.chatwootConfig', () => {
    window.chatwootConfig = undefined;
    const config = useConfig();

    expect(config.hostURL).toBeUndefined();
    expect(config.vapidPublicKey).toBeUndefined();
    expect(config.enabledLanguages).toBeUndefined();
    expect(config.isEnterprise).toBe(false);
    expect(config.enterprisePlanName).toBeUndefined();
  });
});
