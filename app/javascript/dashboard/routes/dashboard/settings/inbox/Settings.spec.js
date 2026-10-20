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

  it('offers WhatsApp reauthorization for a failed deletion recovery', () => {
    expect(
      Settings.computed.whatsappUnauthorized.call({
        isAWhatsAppCloudChannel: true,
        inbox: {
          reauthorization_required: false,
          requires_reauthorization: false,
          deletion_recovery: { status: 'failed' },
          provider_config: { token_health: { status: 'healthy' } },
        },
        whatsappTokenExpiring: false,
        whatsappRegistrationIncomplete: false,
      })
    ).toBe(true);
  });

  it('shows registration recovery independently of the Meta token lifecycle', () => {
    const context = {
      isAWhatsAppCloudChannel: true,
      inbox: {
        reauthorization_required: false,
        requires_reauthorization: false,
        provider_config: {
          phone_registration: { status: 'pin_incorrect' },
        },
      },
      healthData: null,
      whatsappTokenExpiring: false,
    };
    context.whatsappRegistrationIncomplete =
      Settings.computed.whatsappRegistrationIncomplete.call(context);

    expect(context.whatsappRegistrationIncomplete).toBe(true);
    expect(Settings.computed.whatsappUnauthorized.call(context)).toBe(true);
  });

  it('uses reconciled health registration state over a stale inbox snapshot', () => {
    expect(
      Settings.computed.whatsappRegistrationIncomplete.call({
        isAWhatsAppCloudChannel: true,
        inbox: {
          provider_config: {
            embedded_signup_flow: 'standard',
            phone_registration: { status: 'outcome_unknown' },
          },
        },
        healthData: { phone_registration: { status: 'registered' } },
      })
    ).toBe(false);
  });

  it('keeps a hard token failure above a stale registration error', () => {
    const context = {
      isAWhatsAppCloudChannel: true,
      inbox: {
        reauthorization_required: false,
        requires_reauthorization: false,
        provider_config: {
          token_health: { status: 'invalid' },
          phone_registration: { status: 'pin_incorrect' },
        },
      },
      healthData: null,
      whatsappTokenExpiring: false,
    };
    context.whatsappRegistrationIncomplete =
      Settings.computed.whatsappRegistrationIncomplete.call(context);

    expect(context.whatsappRegistrationIncomplete).toBe(false);
    expect(Settings.computed.whatsappUnauthorized.call(context)).toBe(true);
  });

  it('never offers Cloud phone registration for coexistence channels', () => {
    expect(
      Settings.computed.whatsappRegistrationIncomplete.call({
        isAWhatsAppCloudChannel: true,
        inbox: {
          provider_config: { embedded_signup_flow: 'coexistence' },
        },
        healthData: {
          platform_type: 'NOT_APPLICABLE',
          throughput: { level: 'NOT_APPLICABLE' },
        },
      })
    ).toBe(false);
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

describe('Group chat sync settings & Telegram Personal status', () => {
  it('hides stale telegramPersonalLastError when channel is connected', () => {
    expect(
      Settings.computed.telegramPersonalLastError.call({
        isTelegramPersonalConnected: true,
        inbox: { last_error: 'Cannot enter the confirmation code' },
        telegramPersonalDiagnostics: {
          last_error: 'Cannot enter the confirmation code',
        },
        telegramPersonalRuntimeState: {
          last_error: 'Cannot enter the confirmation code',
        },
      })
    ).toBe('');
  });

  it('reads telegramPersonalSyncGroups from runtime_state', () => {
    expect(
      Settings.computed.telegramPersonalSyncGroups.call({
        telegramPersonalRuntimeState: {},
      })
    ).toBe(false);

    expect(
      Settings.computed.telegramPersonalSyncGroups.call({
        telegramPersonalRuntimeState: { sync_groups: true },
      })
    ).toBe(true);
  });

  it('persists sync_groups when toggling Telegram Personal group sync', async () => {
    const dispatch = vi.fn().mockResolvedValue({});
    const fetchTelegramPersonalDiagnostics = vi.fn().mockResolvedValue({});
    const context = {
      currentInboxId: 25,
      telegramPersonalRuntimeState: { ignored_chat_ids: ['123'] },
      isSavingTelegramPersonalSyncGroups: false,
      $store: { dispatch },
      $t: key => key,
      fetchTelegramPersonalDiagnostics,
    };

    await Settings.methods.toggleTelegramPersonalSyncGroups.call(context, {
      target: { checked: true },
    });

    expect(dispatch).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 25,
      formData: false,
      channel: {
        runtime_state: {
          ignored_chat_ids: ['123'],
          sync_groups: true,
        },
      },
    });
    expect(fetchTelegramPersonalDiagnostics).toHaveBeenCalledWith(true);
    expect(context.isSavingTelegramPersonalSyncGroups).toBe(false);
  });
});
