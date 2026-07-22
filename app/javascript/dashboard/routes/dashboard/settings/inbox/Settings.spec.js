import { afterEach, describe, expect, it } from 'vitest';
import Settings from './Settings.vue';

const originalChatwootConfig = window.chatwootConfig;

const expiringInbox = {
  reauthorization_required: false,
  requires_reauthorization: false,
  provider_config: { token_health: { status: 'expiring' } },
};

describe('WhatsApp reauthorization visibility', () => {
  afterEach(() => {
    window.chatwootConfig = originalChatwootConfig;
  });

  it('keeps proactive reauthorization hidden until the rollout flag is enabled', () => {
    window.chatwootConfig = { whatsappProactiveReauthorizationEnabled: false };

    expect(
      Settings.computed.whatsappTokenExpiring.call({
        isAWhatsAppCloudChannel: true,
        inbox: expiringInbox,
      })
    ).toBe(false);
  });

  it('shows proactive reauthorization after the rollout flag is enabled', () => {
    window.chatwootConfig = { whatsappProactiveReauthorizationEnabled: true };

    expect(
      Settings.computed.whatsappTokenExpiring.call({
        isAWhatsAppCloudChannel: true,
        inbox: expiringInbox,
      })
    ).toBe(true);
  });

  it('preserves the legacy hard reauthorization alias', () => {
    expect(
      Settings.computed.whatsappUnauthorized.call({
        isAWhatsAppCloudChannel: true,
        inbox: {
          reauthorization_required: false,
          requires_reauthorization: true,
        },
        whatsappTokenExpiring: false,
      })
    ).toBe(true);
  });
});
