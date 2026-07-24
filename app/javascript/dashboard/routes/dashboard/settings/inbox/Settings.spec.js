import { afterEach, describe, expect, it, vi } from 'vitest';
import Settings from './Settings.vue';
import InboxHealthAPI from 'dashboard/api/inboxHealth';

const originalChatwootConfig = window.chatwootConfig;

const expiringInbox = {
  reauthorization_required: false,
  requires_reauthorization: false,
  provider_config: { token_health: { status: 'expiring' } },
};

describe('WhatsApp reauthorization visibility', () => {
  afterEach(() => {
    window.chatwootConfig = originalChatwootConfig;
    vi.restoreAllMocks();
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

describe('WhatsApp health requests', () => {
  const buildContext = inboxId => ({
    inbox: { id: inboxId },
    isAWhatsAppCloudChannel: true,
    healthData: { phone_number: 'stale' },
    healthError: null,
    isLoadingHealth: false,
    healthRequestId: 0,
  });

  afterEach(() => vi.restoreAllMocks());

  it('does not apply a response from the previously selected inbox', async () => {
    let resolveFirst;
    vi.spyOn(InboxHealthAPI, 'getHealthStatus')
      .mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolveFirst = resolve;
          })
      )
      .mockResolvedValueOnce({ data: { phone_number: 'second' } });
    const context = buildContext(1);

    const firstRequest = Settings.methods.fetchHealthData.call(context);
    context.inbox = { id: 2 };
    const secondRequest = Settings.methods.fetchHealthData.call(context);
    await secondRequest;
    resolveFirst({ data: { phone_number: 'first' } });
    await firstRequest;

    expect(context.healthData).toEqual({ phone_number: 'second' });
  });

  it('clears previous inbox health when the new request fails', async () => {
    vi.spyOn(InboxHealthAPI, 'getHealthStatus').mockRejectedValue(
      new Error('health unavailable')
    );
    const context = buildContext(2);

    await Settings.methods.fetchHealthData.call(context);

    expect(context.healthData).toBeNull();
    expect(context.healthError).toBe('health unavailable');
  });
});
