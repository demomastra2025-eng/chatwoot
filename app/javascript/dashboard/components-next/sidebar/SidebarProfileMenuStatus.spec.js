import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import SidebarProfileMenuStatus from './SidebarProfileMenuStatus.vue';

const { webphoneClient, storeDispatch } = vi.hoisted(() => {
  const listeners = {};
  return {
    storeDispatch: vi.fn(),
    webphoneClient: {
      sessions: {},
      bootstrapIncomingSupport: vi.fn(() => Promise.resolve()),
      initializeDevice: vi.fn(() => Promise.resolve()),
      addEventListener: vi.fn((event, callback) => {
        listeners[event] = callback;
      }),
      removeEventListener: vi.fn((event, callback) => {
        if (listeners[event] === callback) delete listeners[event];
      }),
      emit: event => listeners[event]?.(),
    },
  };
});

vi.mock('dashboard/api/channel/voice/webphoneClient', () => ({
  default: webphoneClient,
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch: storeDispatch }),
  useMapGetter: getter => {
    const values = {
      getCurrentUserAvailability: 'online',
      getCurrentAccountId: 1,
      getCurrentUserAutoOffline: false,
      'inboxes/getInboxes': [
        { id: 43, name: 'Отдел продаж' },
        { id: 44, name: 'Поддержка' },
      ],
    };
    return ref(values[getter]);
  },
}));

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useImpersonation', () => ({
  useImpersonation: () => ({ isImpersonating: ref(false) }),
}));

const translations = {
  'SIDEBAR.SIP_TELEPHONY.LABEL': 'SIP-телефония',
  'SIDEBAR.SIP_TELEPHONY.RECONNECT': 'Переподключить SIP',
  'SIDEBAR.SIP_TELEPHONY.CHANNEL_LABEL': 'SIP ({name})',
  'SIDEBAR.SIP_TELEPHONY.CHANNEL_FALLBACK': 'Канал',
  'SIDEBAR.SIP_TELEPHONY.STATUS.READY': 'Готова к звонкам',
  'SIDEBAR.SIP_TELEPHONY.STATUS.CONNECTING': 'Подключение…',
  'SIDEBAR.SIP_TELEPHONY.STATUS.DISCONNECTED': 'Не подключена',
  'SIDEBAR.SIP_TELEPHONY.STATUS.ACTIVE_IN_ANOTHER_TAB':
    'Активна в другой вкладке',
  'SIDEBAR.SIP_TELEPHONY.STATUS.ERROR': 'Ошибка подключения',
};
const translate = (key, params = {}) =>
  (translations[key] || key).replace(
    /\{(\w+)\}/g,
    (_, name) => params[name] ?? `{${name}}`
  );

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: translate }),
}));

const mountComponent = () =>
  mount(SidebarProfileMenuStatus, {
    global: {
      mocks: { $t: translate },
      stubs: {
        DropdownSection: { template: '<section><slot /></section>' },
        DropdownContainer: {
          template:
            '<div><slot name="trigger" :toggle="() => {}" /><slot /></div>',
        },
        DropdownBody: { template: '<div><slot /></div>' },
        DropdownItem: { template: '<div><slot /></div>' },
        Button: { template: '<button><slot /></button>' },
        Icon: {
          props: ['icon'],
          template: '<i :data-icon="icon" />',
        },
        ToggleSwitch: { template: '<button />' },
      },
    },
  });

const sipSession = overrides => ({
  provider: 'sipuni',
  inboxId: 43,
  sipProfileId: 83,
  sessionKey: 'sip_profile:83',
  callingSupported: true,
  registered: true,
  reason: null,
  ...overrides,
});

describe('SidebarProfileMenuStatus', () => {
  beforeEach(() => {
    webphoneClient.sessions = {};
    webphoneClient.bootstrapIncomingSupport.mockReset();
    webphoneClient.bootstrapIncomingSupport.mockResolvedValue();
    webphoneClient.initializeDevice.mockReset();
    webphoneClient.initializeDevice.mockResolvedValue();
    webphoneClient.addEventListener.mockClear();
    webphoneClient.removeEventListener.mockClear();
  });

  it('hides SIP status when the user has no browser SIP call channel', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.find('[data-testid="sip-telephony-status"]').exists()).toBe(
      false
    );
  });

  it('shows every SIP channel with its own realtime status', async () => {
    webphoneClient.sessions = {
      'sip_profile:83': sipSession(),
      'sip_profile:84': sipSession({
        provider: 'binotel',
        inboxId: 44,
        sipProfileId: 84,
        sessionKey: 'sip_profile:84',
        registered: false,
        callingSupported: false,
        reason: 'sip_provider_credentials_failed',
      }),
    };

    const wrapper = mountComponent();
    await flushPromises();
    const rows = wrapper.findAll('[data-testid="sip-telephony-status"]');
    const indicators = wrapper.findAll(
      '[data-testid="sip-telephony-indicator"]'
    );

    expect(rows).toHaveLength(2);
    expect(rows[0].find('div').text()).toBe('SIP (Отдел продаж)');
    expect(rows[0].text()).not.toContain('Sipuni');
    expect(rows[1].find('div').text()).toBe('SIP (Поддержка)');
    expect(rows[1].text()).not.toContain('Binotel');
    expect(indicators[0].attributes('disabled')).toBeDefined();
    expect(indicators[0].find('i').attributes('data-icon')).toBe(
      'i-lucide-circle-check'
    );
    expect(indicators[0].find('span').classes()).not.toContain('sr-only');
    expect(indicators[0].find('span').text()).toBe('Готова к звонкам');
    expect(indicators[0].classes()).toContain('text-[#008573]');
    expect(indicators[0].classes()).toContain('disabled:opacity-100');
    expect(indicators[0].classes()).not.toContain('bg-n-teal-3');
    expect(indicators[0].element.lastElementChild.tagName).toBe('I');
    expect(indicators[1].attributes('disabled')).toBeUndefined();
    expect(indicators[1].classes()).toContain('text-[#ca244d]');
    expect(indicators[1].classes()).not.toContain('bg-n-ruby-3');
    expect(indicators[1].find('i').attributes('data-icon')).toBe(
      'i-lucide-refresh-cw'
    );

    webphoneClient.sessions['sip_profile:84'].registered = true;
    webphoneClient.sessions['sip_profile:84'].callingSupported = true;
    webphoneClient.emit('call:sessions-changed');
    await flushPromises();

    expect(indicators[1].attributes('disabled')).toBeDefined();
    expect(indicators[1].find('i').attributes('data-icon')).toBe(
      'i-lucide-circle-check'
    );

    delete webphoneClient.sessions['sip_profile:84'];
    webphoneClient.emit('call:sessions-changed');
    await flushPromises();

    expect(
      wrapper.findAll('[data-testid="sip-telephony-status"]')
    ).toHaveLength(1);
  });

  it('uses the combined status indicator to reconnect a disconnected SIP channel', async () => {
    webphoneClient.sessions = {
      'sip_profile:83': sipSession({
        registered: false,
        reason: 'sip_unregistered',
      }),
    };
    let resolveReconnect;
    webphoneClient.initializeDevice.mockReturnValue(
      new Promise(resolve => {
        resolveReconnect = resolve;
      })
    );

    const wrapper = mountComponent();
    await flushPromises();
    const indicator = wrapper.get('[data-testid="sip-telephony-indicator"]');

    expect(indicator.text()).toContain('Не подключена');
    await indicator.trigger('click');

    expect(webphoneClient.initializeDevice).toHaveBeenCalledWith(43, {
      native: true,
      provider: 'sipuni',
      sipProfileId: 83,
      sessionKey: 'sip_profile:83',
    });
    expect(indicator.text()).toContain('Подключение…');

    webphoneClient.sessions['sip_profile:83'].registered = true;
    resolveReconnect();
    await flushPromises();
    expect(indicator.text()).toContain('Готова к звонкам');
  });

  it('shows a non-error standby state when SIP is active in another tab', async () => {
    webphoneClient.sessions = {
      'sip_profile:83': sipSession({
        registered: false,
        callingSupported: false,
        reason: 'sip_profile_registration_lease_owned_by_another_tab',
      }),
    };

    const wrapper = mountComponent();
    await flushPromises();

    const indicator = wrapper.get('[data-testid="sip-telephony-indicator"]');
    expect(indicator.text()).toContain('Активна в другой вкладке');
    expect(indicator.attributes('disabled')).toBeDefined();
    expect(indicator.attributes('title')).toBe('Активна в другой вкладке');
    expect(indicator.classes()).toContain('text-n-slate-11');
    expect(indicator.find('i').attributes('data-icon')).toBe(
      'i-lucide-monitor'
    );
  });

  it('shows a reconnectable error for a failed SIP session', async () => {
    webphoneClient.sessions = {
      'sip_profile:83': sipSession({
        registered: false,
        callingSupported: false,
        reason: 'sip_provider_credentials_failed',
      }),
    };

    const wrapper = mountComponent();
    await flushPromises();

    const indicator = wrapper.get('[data-testid="sip-telephony-indicator"]');
    expect(indicator.text()).toContain('Ошибка подключения');
    expect(indicator.attributes('disabled')).toBeUndefined();
    expect(indicator.attributes('title')).toBe('Переподключить SIP');
  });
});
