import { flushPromises, mount } from '@vue/test-utils';
import PhoneWidget from './PhoneWidget.vue';

const { webphoneClient, callsState, values } = vi.hoisted(() => {
  const listeners = {};
  return {
    values: { 'inboxes/getInboxes': [], getCurrentAccountId: 1 },
    callsState: { hasActiveCall: false, hasIncomingCall: false },
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
vi.mock('dashboard/stores/calls', () => ({
  useCallsStore: () => callsState,
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

const voiceInbox = (id = 43) => ({
  id,
  name: `Line ${id}`,
  channel_type: 'Channel::Voice',
  provider: 'sipuni',
});
const sipSession = (overrides = {}) => ({
  provider: 'sipuni',
  inboxId: 43,
  sipProfileId: 83,
  sessionKey: 'sip_profile:83',
  callingSupported: true,
  registered: true,
  ...overrides,
});
const mountComponent = () =>
  mount(PhoneWidget, {
    global: {
      stubs: {
        VoiceCallButton: {
          props: ['phone', 'inboxId', 'disabled'],
          emits: ['callInitiated'],
          template:
            '<button data-testid="phone-widget-call" :disabled="disabled" @click="$emit(\'callInitiated\')">{{ phone }} · {{ inboxId }}</button>',
          methods: {
            onClick() {
              this.$emit('callInitiated');
            },
          },
        },
      },
    },
  });

describe('PhoneWidget', () => {
  beforeEach(() => {
    values['inboxes/getInboxes'] = [voiceInbox()];
    values.getCurrentAccountId = 1;
    callsState.hasActiveCall = false;
    callsState.hasIncomingCall = false;
    webphoneClient.sessions = { 'sip_profile:83': sipSession() };
    webphoneClient.bootstrapIncomingSupport.mockReset().mockResolvedValue();
    webphoneClient.initializeDevice.mockReset().mockResolvedValue();
    webphoneClient.addEventListener.mockClear();
    webphoneClient.removeEventListener.mockClear();
  });

  it('does not expose the phone to users without a browser voice inbox', async () => {
    values['inboxes/getInboxes'] = [{ id: 1, channel_type: 'Channel::Email' }];
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.find('[data-testid="phone-widget"]').exists()).toBe(false);
    expect(webphoneClient.bootstrapIncomingSupport).not.toHaveBeenCalled();
  });

  it('does not expose account-wide voice inboxes without an assigned webphone session', async () => {
    webphoneClient.sessions = {};
    const wrapper = mountComponent();
    await flushPromises();

    expect(webphoneClient.bootstrapIncomingSupport).toHaveBeenCalledOnce();
    expect(wrapper.find('[data-testid="phone-widget"]').exists()).toBe(false);
  });

  it('shows live status outside the profile and keeps sessions running while hidden', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.get('[role="status"]').text()).toContain('READY');
    expect(webphoneClient.bootstrapIncomingSupport).toHaveBeenCalledOnce();
    await wrapper.get('[data-testid="phone-widget-hide"]').trigger('click');
    expect(wrapper.find('[data-testid="phone-widget-panel"]').exists()).toBe(
      false
    );
    expect(
      wrapper.get('[data-testid="phone-widget-launcher"]').attributes('title')
    ).toContain('READY');

    webphoneClient.sessions['sip_profile:83'].registered = false;
    webphoneClient.emit('call:sessions-changed');
    await flushPromises();
    expect(
      wrapper.get('[data-testid="phone-widget-launcher"]').attributes('title')
    ).toContain('DISCONNECTED');
    expect(webphoneClient.bootstrapIncomingSupport).toHaveBeenCalledOnce();
    await wrapper.get('[data-testid="phone-widget-launcher"]').trigger('click');
    expect(wrapper.get('[role="status"]').text()).toContain('DISCONNECTED');
    wrapper.unmount();
    expect(webphoneClient.removeEventListener).toHaveBeenCalledWith(
      'call:sessions-changed',
      expect.any(Function)
    );
  });

  it('shows the translated other-tab state without offering a reconnect', async () => {
    webphoneClient.sessions['sip_profile:83'] = sipSession({
      registered: false,
      callingSupported: false,
      reason: 'sip_profile_registration_lease_owned_by_another_tab',
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.get('[role="status"]').text()).toContain(
      'ACTIVE_IN_ANOTHER_TAB'
    );
    await wrapper.get('[data-testid="phone-widget-expand"]').trigger('click');
    expect(
      wrapper.find('[data-testid="phone-widget-reconnect"]').exists()
    ).toBe(false);
  });

  it('keeps number entry available when minimized and supports mouse dialing with a plus', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    const input = wrapper.get('[data-testid="phone-widget-number"]');
    await input.setValue('77712345678');
    expect(wrapper.get('[data-testid="phone-widget-call"]').text()).toContain(
      '77712345678'
    );

    await wrapper.get('[data-testid="phone-widget-expand"]').trigger('click');
    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      true
    );
    await wrapper.get('[data-testid="phone-widget-plus"]').trigger('click');
    expect(input.element.value).toBe('+77712345678');
    await wrapper.get('[data-testid="phone-key-1"]').trigger('click');
    expect(input.element.value).toBe('+777123456781');
    await wrapper
      .get('[aria-label="PHONE_WIDGET.DELETE_DIGIT"]')
      .trigger('click');
    expect(input.element.value).toBe('+77712345678');
    await wrapper.get('[data-testid="phone-widget-expand"]').trigger('click');
    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      false
    );
    expect(
      wrapper.get('[data-testid="phone-widget-number"]').element.value
    ).toBe('+77712345678');
  });

  it('shows per-line status and reconnects the selected failed session', async () => {
    values['inboxes/getInboxes'] = [voiceInbox(43), voiceInbox(44)];
    webphoneClient.sessions['sip_profile:84'] = sipSession({
      inboxId: 44,
      sipProfileId: 84,
      sessionKey: 'sip_profile:84',
      registered: false,
      callingSupported: false,
      reason: 'sip_credentials_failed',
    });
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper.get('[data-testid="phone-widget-inbox"]').setValue('44');
    expect(wrapper.get('[role="status"]').text()).toContain('ERROR');
    await wrapper.get('[data-testid="phone-widget-expand"]').trigger('click');
    await wrapper
      .get('[data-testid="phone-widget-reconnect"]')
      .trigger('click');
    expect(webphoneClient.initializeDevice).toHaveBeenCalledWith(44, {
      native: true,
      provider: 'sipuni',
      sipProfileId: 84,
      sessionKey: 'sip_profile:84',
    });
  });
});
