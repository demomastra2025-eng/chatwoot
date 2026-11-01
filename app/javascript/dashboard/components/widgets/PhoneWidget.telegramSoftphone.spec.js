import { flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import PhoneWidget from './PhoneWidget.vue';

const {
  webphoneClient,
  callsState,
  values,
  settingsState,
  microphoneState,
  alertMock,
  telegramApiMock,
} = await vi.hoisted(async () => {
  const { reactive, ref } = await import('vue');
  return {
    alertMock: vi.fn(),
    telegramApiMock: {
      getStatus: vi.fn(),
      issueLinkToken: vi.fn(),
      setOnLine: vi.fn(),
    },
    values: {
      'inboxes/getInboxes': [
        {
          id: 43,
          name: 'Line 43',
          channel_type: 'Channel::Voice',
          provider: 'wazo',
        },
      ],
      getCurrentAccountId: 1,
      getCurrentUser: { name: 'Асет' },
    },
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
    expect(bar.text()).toContain('@zhanar_od');

    const statusBadge = wrapper.find(
      '[data-testid="phone-widget-telegram-status"]'
    );
    expect(statusBadge.text()).toContain('PHONE_WIDGET.TELEGRAM_OFFLINE');

    const btn = wrapper.find('[data-testid="phone-widget-telegram-action"]');
    expect(btn.text()).toContain('PHONE_WIDGET.TELEGRAM_GO_ONLINE');

    await btn.trigger('click');
    await flushPromises();
    expect(telegramApiMock.setOnLine).toHaveBeenNthCalledWith(1, true);
    expect(statusBadge.text()).toContain('PHONE_WIDGET.TELEGRAM_ONLINE');
    expect(btn.text()).toContain(
      'PROFILE_SETTINGS.FORM.TELEGRAM_SOFTPHONE.GO_OFFLINE_BTN'
    );

    webphoneClient.bootstrapIncomingSupport.mockClear();
    await btn.trigger('click');
    await flushPromises();
    expect(telegramApiMock.setOnLine).toHaveBeenNthCalledWith(2, false);
    expect(statusBadge.text()).toContain('PHONE_WIDGET.TELEGRAM_OFFLINE');
    expect(webphoneClient.bootstrapIncomingSupport).toHaveBeenCalledTimes(1);
  });
});
