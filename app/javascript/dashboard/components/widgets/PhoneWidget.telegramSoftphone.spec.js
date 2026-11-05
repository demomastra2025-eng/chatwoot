import { flushPromises, mount, enableAutoUnmount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import PhoneWidget from './PhoneWidget.vue';
import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';

const {
  webphoneClient,
  callsState,
  values,
  settingsState,
  microphoneState,
  alertMock,
  telegramApiMock,
  featureAccess,
} = await vi.hoisted(async () => {
  const { reactive, ref } = await import('vue');
  const accessByAccount = reactive({ 1: true, 2: true });
  return {
    featureAccess: accessByAccount,
    alertMock: vi.fn(),
    telegramApiMock: {
      getStatus: vi.fn(),
      issueLinkToken: vi.fn(),
      setOnLine: vi.fn(),
    },
    values: reactive({
      'inboxes/getInboxes': [
        {
          id: 43,
          name: 'Line 43',
          channel_type: 'Channel::Voice',
          provider: 'wazo',
        },
      ],
      getCurrentAccountId: 1,
      'accounts/isFeatureEnabledonAccount': (id, flag) =>
        flag === 'telegram_calls_bot' && accessByAccount[id] === true,
      getCurrentUser: { name: 'Асет' },
    }),
    callsState: reactive({
      activeCall: null,
      hasActiveCall: false,
      hasIncomingCall: false,
      incomingCalls: [],
    }),
    settingsState: {
      settings: ref({}),
      update: vi.fn(),
    },
    microphoneState: {
      available: ref(false),
      muted: ref(false),
      toggle: vi.fn(),
    },
    webphoneClient: {
      sessions: {
        'sip_profile:83': {
          provider: 'wazo',
          inboxId: 43,
          sipProfileId: 83,
          sessionKey: 'sip_profile:83',
          callingSupported: true,
          registered: true,
        },
      },
      bootstrapIncomingSupport: vi.fn(() => Promise.resolve()),
      initializeDevice: vi.fn(() => Promise.resolve()),
      destroyDevice: vi.fn(),
      destroyNativeSession: vi.fn(),
      releaseNativeOwnership: vi.fn(),
      suspendNativeSessions: vi.fn(),
      endClientCall: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    },
  };
});
enableAutoUnmount(afterEach);

vi.mock('dashboard/composables/useWhatsappCallInitiation', async () => {
  const { ref } = await import('vue');
  return {
    useWhatsappCallInitiation: () => ({
      canInitiateWhatsappCall: ref(true),
      isInitiatingWhatsappCall: ref(false),
      initiateWhatsappCall: vi.fn(),
    }),
  };
});
vi.mock('dashboard/api/telephony/telegramSoftphone', () => ({
  default: telegramApiMock,
}));
vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: webphoneClient,
}));
vi.mock('dashboard/composables', () => ({
  useAlert: alertMock,
}));
vi.mock('dashboard/stores/calls', async importOriginal => ({
  ...(await importOriginal()),
  useCallsStore: () => callsState,
}));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: settingsState.settings,
    updateUISettings: settingsState.update,
  }),
}));
vi.mock('dashboard/composables/useSipMicrophone', () => ({
  useSipMicrophone: () => ({
    microphoneAvailable: microphoneState.available,
    microphoneMuted: microphoneState.muted,
    toggleMicrophone: microphoneState.toggle,
  }),
}));
vi.mock('dashboard/composables/store', async () => {
  const { computed } = await vi.importActual('vue');
  return {
    useMapGetter: getter => computed(() => values[getter]),
  };
});
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

describe('PhoneWidget Telegram softphone bar', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    setActivePinia(createPinia());
    featureAccess[1] = true;
    featureAccess[2] = true;
    values.getCurrentAccountId = 1;
  });

  it('hides the bot and never starts polling when access is off', async () => {
    vi.useFakeTimers();
    featureAccess[1] = false;
    const wrapper = mount(PhoneWidget, {
      global: {
        stubs: {
          FloatingCallWidget: true,
          WhatsappCallWidget: true,
          VoiceCallButton: true,
          ComboBox: true,
        },
      },
    });
    await flushPromises();
    await vi.advanceTimersByTimeAsync(30_000);
    expect(telegramApiMock.getStatus).not.toHaveBeenCalled();
    expect(
      wrapper.find('[data-testid="phone-widget-telegram-softphone"]').exists()
    ).toBe(false);
    wrapper.unmount();
    vi.useRealTimers();
  });

  it('stops bot polling and discards a pending response after revocation', async () => {
    vi.useFakeTimers();
    let resolveStatus;
    telegramApiMock.getStatus.mockReturnValueOnce(
      new Promise(resolve => {
        resolveStatus = resolve;
      })
    );
    const wrapper = mount(PhoneWidget, {
      global: {
        stubs: {
          FloatingCallWidget: true,
          WhatsappCallWidget: true,
          VoiceCallButton: true,
          ComboBox: true,
        },
      },
    });
    featureAccess[1] = false;
    await flushPromises();
    resolveStatus({ configured: true, connected: true, on_line: true });
    await flushPromises();
    await vi.advanceTimersByTimeAsync(30_000);
    expect(telegramApiMock.getStatus).toHaveBeenCalledTimes(1);
    expect(
      wrapper.find('[data-testid="phone-widget-telegram-softphone"]').exists()
    ).toBe(false);
    wrapper.unmount();
    vi.useRealTimers();
  });

  it('renders compact bar when configured and toggles on-line / off-line', async () => {
    telegramApiMock.getStatus.mockResolvedValue({
      configured: true,
      connected: true,
      on_line: false,
      username: 'zhanar_od',
    });
    telegramApiMock.setOnLine
      .mockResolvedValueOnce({
        configured: true,
        connected: true,
        on_line: true,
        username: 'zhanar_od',
        sip_lines: [{ inbox_id: 43, registered: true }],
      })
      .mockResolvedValueOnce({
        configured: true,
        connected: true,
        on_line: false,
        username: 'zhanar_od',
      });

    const wrapper = mount(PhoneWidget, {
      global: {
        directives: { 'on-clickaway': {} },
        stubs: {
          VoiceCallButton: { template: '<button />' },
          FloatingCallWidget: { template: '<div />' },
          WhatsappCallWidget: { template: '<div />' },
        },
      },
    });
    await flushPromises();

    const bar = wrapper.find('[data-testid="phone-widget-telegram-softphone"]');
    expect(bar.exists()).toBe(true);
    expect(bar.text()).toContain('PHONE_WIDGET.TELEGRAM_CALLS_LABEL');

    const statusBadge = wrapper.find(
      '[data-testid="phone-widget-telegram-status"]'
    );
    expect(statusBadge.text()).toContain('PHONE_WIDGET.TELEGRAM_OFFLINE');

    const btn = wrapper.find('[data-testid="phone-widget-telegram-action"]');
    expect(btn.text()).toContain('PHONE_WIDGET.TELEGRAM_GO_ONLINE');

    webphoneClient.bootstrapIncomingSupport.mockClear();
    await btn.trigger('click');
    await flushPromises();
    expect(telegramApiMock.setOnLine).toHaveBeenNthCalledWith(1, true);
    expect(statusBadge.text()).toContain('PHONE_WIDGET.TELEGRAM_ONLINE');
    expect(btn.text()).toContain(
      'PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.GO_OFFLINE_BTN'
    );
    expect(webphoneClient.bootstrapIncomingSupport).not.toHaveBeenCalled();

    webphoneClient.bootstrapIncomingSupport.mockClear();
    await btn.trigger('click');
    await flushPromises();
    expect(telegramApiMock.setOnLine).toHaveBeenNthCalledWith(2, false);
    expect(statusBadge.text()).toContain('PHONE_WIDGET.TELEGRAM_OFFLINE');
    expect(webphoneClient.bootstrapIncomingSupport).toHaveBeenCalledTimes(1);
  });

  it('shows Telegram in the line list and reports SIP registration errors instead of online', async () => {
    telegramApiMock.getStatus.mockResolvedValue({
      configured: true,
      connected: true,
      on_line: true,
      username: 'operator',
      sip_lines: [{ inbox_id: 43, registered: false, error: 'unauthorized' }],
    });
    const wrapper = mount(PhoneWidget, {
      global: {
        directives: { 'on-clickaway': {} },
        stubs: {
          VoiceCallButton: { template: '<button />' },
          FloatingCallWidget: { template: '<div />' },
          WhatsappCallWidget: { template: '<div />' },
        },
      },
    });
    await flushPromises();
    await wrapper
      .find('[data-testid="phone-widget-lines-toggle"]')
      .trigger('click');
    const telegramLine = wrapper.find('[data-line-id="telegram"]');
    expect(telegramLine.exists()).toBe(false);
    expect(
      wrapper.find('[data-testid="phone-widget-telegram-status"]').text()
    ).toContain('PHONE_WIDGET.TELEGRAM_ERROR');
  });

  it('keeps an online request in registration state until a SIP line registers', async () => {
    telegramApiMock.getStatus.mockResolvedValue({
      configured: true,
      connected: true,
      on_line: true,
      sip_lines: [{ inbox_id: 43, registered: false }],
    });
    const wrapper = mount(PhoneWidget, {
      global: {
        directives: { 'on-clickaway': {} },
        stubs: {
          VoiceCallButton: { template: '<button />' },
          FloatingCallWidget: { template: '<div />' },
          WhatsappCallWidget: { template: '<div />' },
        },
      },
    });
    await flushPromises();
    expect(
      wrapper.find('[data-testid="phone-widget-telegram-status"]').text()
    ).toContain('PHONE_WIDGET.TELEGRAM_REGISTERING');
  });
  it('shows and persists a Telegram-only native line without offering a SIP call', async () => {
    featureAccess[1] = false;
    featureAccess[2] = false;
    values['inboxes/getInboxes'] = [
      {
        id: 225,
        name: 'Telegram native',
        channel_type: 'Channel::TelegramPersonal',
        calling_enabled: true,
        connection_state: 'connected',
      },
    ];
    telegramApiMock.getStatus.mockResolvedValue({ configured: false });
    const wrapper = mount(PhoneWidget, {
      global: {
        stubs: {
          FloatingCallWidget: true,
          WhatsappCallWidget: true,
          VoiceCallButton: true,
          ComboBox: true,
        },
      },
    });
    await flushPromises();
    expect(telegramApiMock.getStatus).not.toHaveBeenCalled();
    expect(wrapper.find('[data-testid="phone-widget"]').exists()).toBe(true);
    expect(wrapper.find('[data-line-id="225"]').exists()).toBe(true);
    expect(wrapper.findComponent({ name: 'VoiceCallButton' }).exists()).toBe(
      false
    );
    expect(
      wrapper
        .find('[data-testid="phone-widget-native-call"]')
        .attributes('disabled')
    ).toBeDefined();
    await wrapper.find('[data-line-id="225"]').trigger('click');
    expect(String(usePhoneWidgetStore().selectedInboxId)).toBe('225');
    values.getCurrentAccountId = 2;
    values['inboxes/getInboxes'] = [
      {
        id: 226,
        name: 'Other Telegram',
        channel_type: 'Channel::TelegramPersonal',
        calling_enabled: true,
        connection_state: 'connected',
      },
    ];
    await flushPromises();
    expect(String(usePhoneWidgetStore().selectedInboxId)).toBe('226');
    expect(wrapper.find('[data-line-id="225"]').exists()).toBe(false);
    wrapper.unmount();
  });
  it.each([false, true])(
    'fences delayed bot actions after account switch (connected=%s)',
    async connected => {
      values.getCurrentAccountId = 1;
      let resolveAction;
      const pendingAction = new Promise(resolve => {
        resolveAction = resolve;
      });
      telegramApiMock.getStatus.mockResolvedValue({
        configured: true,
        connected,
        on_line: false,
      });
      const apiAction = connected
        ? telegramApiMock.setOnLine
        : telegramApiMock.issueLinkToken;
      apiAction.mockReturnValueOnce(pendingAction);
      const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null);
      const wrapper = mount(PhoneWidget, {
        global: {
          stubs: {
            FloatingCallWidget: true,
            WhatsappCallWidget: true,
            VoiceCallButton: true,
            ComboBox: true,
          },
        },
      });
      await flushPromises();
      await wrapper
        .find('[data-testid="phone-widget-telegram-action"]')
        .trigger('click');
      telegramApiMock.getStatus.mockResolvedValue({ configured: false });
      values.getCurrentAccountId = 2;
      await flushPromises();
      resolveAction({
        configured: true,
        connected: true,
        on_line: true,
        deep_link: 'https://example.test/stale-link',
      });
      await flushPromises();
      expect(
        wrapper.find('[data-testid="phone-widget-telegram-softphone"]').exists()
      ).toBe(false);
      expect(openSpy).not.toHaveBeenCalled();
      wrapper.unmount();
      openSpy.mockRestore();
    }
  );
});
