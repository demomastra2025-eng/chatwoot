import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import PhoneWidget from './PhoneWidget.vue';

const { webphoneClient, callsState, values, settingsState, microphoneState } =
  vi.hoisted(() => {
    const listeners = {};
    return {
      values: {
        'inboxes/getInboxes': [],
        getCurrentAccountId: 1,
        getCurrentUser: { name: 'Иван Иванов' },
      },
      callsState: {
        activeCall: null,
        hasActiveCall: false,
        hasIncomingCall: false,
      },
      settingsState: { settings: null, update: vi.fn() },
      microphoneState: { available: null, muted: null, toggle: vi.fn() },
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
          props: [
            'phone',
            'inboxId',
            'disabled',
            'label',
            'icon',
            'tooltipLabel',
          ],
          emits: ['callInitiated'],
          template:
            '<button data-testid="phone-widget-call" :disabled="disabled" :title="tooltipLabel" @click="$emit(\'callInitiated\')"><span v-if="icon" :class="icon" />{{ label }} · {{ phone }} · {{ inboxId }}</button>',
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
    settingsState.settings = ref({});
    settingsState.update.mockReset().mockImplementation(next => {
      settingsState.settings.value = {
        ...settingsState.settings.value,
        ...next,
      };
    });
    microphoneState.available = ref(false);
    microphoneState.muted = ref(false);
    microphoneState.toggle.mockReset();
    values['inboxes/getInboxes'] = [voiceInbox()];
    values.getCurrentAccountId = 1;
    values.getCurrentUser = { name: 'Иван Иванов' };
    callsState.hasActiveCall = false;
    callsState.hasIncomingCall = false;
    callsState.activeCall = null;
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

    expect(wrapper.get('[role="status"]').text()).toBe('Иван Иванов');
    expect(wrapper.get('[role="status"]').attributes('aria-label')).toContain(
      'READY'
    );
    expect(wrapper.get('[role="status"] span').classes()).toContain(
      'bg-n-teal-9'
    );
    const refresh = wrapper.get('[data-testid="phone-widget-reconnect"]');
    expect(refresh.find('.i-lucide-refresh-cw').exists()).toBe(true);
    expect(refresh.attributes('disabled')).toBeDefined();
    expect(refresh.attributes('aria-label')).toBe('PHONE_WIDGET.ACTIVE');
    expect(refresh.text()).toBe('');
    refresh.element.click();
    await flushPromises();
    expect(webphoneClient.initializeDevice).not.toHaveBeenCalled();
    expect(
      wrapper.get('[data-testid="phone-widget-panel"]').text()
    ).not.toContain('PHONE_WIDGET.TITLE');
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
    expect(wrapper.get('[role="status"]').attributes('aria-label')).toContain(
      'DISCONNECTED'
    );
    wrapper.unmount();
    expect(webphoneClient.removeEventListener).toHaveBeenCalledWith(
      'call:sessions-changed',
      expect.any(Function)
    );
  });

  it('hides the only SIP line and shows an accessible icon-only call action', async () => {
    values['inboxes/getInboxes'] = [
      voiceInbox(),
      { id: 99, channel_type: 'Channel::Whatsapp', can_call: true },
    ];
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.find('[data-testid="phone-widget-line"]').exists()).toBe(
      false
    );
    expect(
      wrapper.find('select[data-testid="phone-widget-inbox"]').exists()
    ).toBe(false);
    const disabledCall = wrapper.get('button[aria-label="PHONE_WIDGET.CALL"]');
    expect(disabledCall.attributes('disabled')).toBeDefined();
    expect(disabledCall.text()).toBe('');
    expect(disabledCall.find('.i-lucide-phone-call').exists()).toBe(true);
    expect(disabledCall.classes()).toContain('bg-n-button-color');

    await wrapper.get('input#phone-widget-number').setValue('77712345678');
    const enabledCall = wrapper.get('[data-testid="phone-widget-call"]');
    expect(enabledCall.find('.i-lucide-phone-call').exists()).toBe(true);
    expect(enabledCall.attributes('aria-label')).toBe('PHONE_WIDGET.CALL');
    expect(enabledCall.attributes('title')).toBe('PHONE_WIDGET.CALL');
    expect(enabledCall.text()).not.toContain('PHONE_WIDGET.CALL');
    expect(enabledCall.text()).toContain('43');
  });

  it('keeps the microphone visible when idle and collapsed, but disabled', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const microphone = wrapper.get('[data-testid="phone-widget-microphone"]');
    expect(microphone.attributes('disabled')).toBeDefined();
    expect(microphone.find('.i-lucide-mic').exists()).toBe(true);
    expect(microphone.attributes('aria-label')).toBe(
      'PHONE_WIDGET.MICROPHONE_UNAVAILABLE'
    );
    microphone.element.click();
    expect(microphoneState.toggle).not.toHaveBeenCalled();

    await wrapper.get('[data-testid="phone-widget-hide"]').trigger('click');
    expect(
      wrapper
        .get('[data-testid="phone-widget-microphone"]')
        .attributes('disabled')
    ).toBeDefined();
    expect(wrapper.get('[data-testid="phone-widget-launcher"]').exists()).toBe(
      true
    );
  });

  it('switches the connected microphone and keeps the ringtone separate', async () => {
    microphoneState.available.value = true;
    callsState.activeCall = { isActive: true, callSid: 'sipuni:call-1' };
    const wrapper = mountComponent();
    await flushPromises();

    const microphone = wrapper.get('[data-testid="phone-widget-microphone"]');
    expect(microphone.attributes('disabled')).toBeUndefined();
    expect(microphone.attributes('aria-label')).toBe(
      'PHONE_WIDGET.MUTE_MICROPHONE'
    );
    await microphone.trigger('click');
    expect(microphoneState.toggle).toHaveBeenCalledOnce();
    microphoneState.muted.value = true;
    await wrapper.vm.$nextTick();
    expect(microphone.find('.i-lucide-mic-off').exists()).toBe(true);
    expect(microphone.attributes('aria-label')).toBe(
      'PHONE_WIDGET.UNMUTE_MICROPHONE'
    );

    const ringtone = wrapper.get('[data-testid="phone-widget-ringtone"]');
    expect(ringtone.attributes('aria-pressed')).toBe('true');
    expect(ringtone.find('.i-lucide-bell').exists()).toBe(true);
    await ringtone.trigger('click');
    expect(settingsState.update).toHaveBeenCalledWith({
      voice_call_ringtone_enabled: false,
    });
    expect(ringtone.find('.i-lucide-bell-off').exists()).toBe(true);
    expect(ringtone.attributes('aria-pressed')).toBe('false');
    expect(microphoneState.muted.value).toBe(true);
    await ringtone.trigger('click');
    expect(settingsState.update).toHaveBeenLastCalledWith({
      voice_call_ringtone_enabled: true,
    });
  });

  it('switches diagonal expand and collapse icons with the keypad', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const toggle = wrapper.get('[data-testid="phone-widget-expand"]');
    expect(toggle.find('.i-lucide-maximize-2').exists()).toBe(true);
    expect(toggle.attributes('aria-label')).toBe('PHONE_WIDGET.EXPAND');
    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      false
    );

    await toggle.trigger('click');
    expect(toggle.find('.i-lucide-minimize-2').exists()).toBe(true);
    expect(toggle.attributes('aria-label')).toBe('PHONE_WIDGET.MINIMIZE');
    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      true
    );

    await toggle.trigger('click');
    expect(toggle.find('.i-lucide-maximize-2').exists()).toBe(true);
    expect(toggle.attributes('aria-label')).toBe('PHONE_WIDGET.EXPAND');
    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      false
    );
  });

  it('uses the current employee display name when a full name is missing', async () => {
    values.getCurrentUser = { name: '', available_name: 'Рабочее имя' };
    const wrapper = mountComponent();
    await flushPromises();
    expect(wrapper.get('[data-testid="phone-widget-employee"]').text()).toBe(
      'Рабочее имя'
    );
  });

  it('uses a neutral indicator and offers reconnect without expanding', async () => {
    webphoneClient.sessions['sip_profile:83'] = sipSession({
      registered: false,
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.get('[role="status"]').attributes('aria-label')).toContain(
      'DISCONNECTED'
    );
    expect(wrapper.get('[role="status"] span').classes()).toContain(
      'bg-n-slate-9'
    );
    const refresh = wrapper.get('[data-testid="phone-widget-reconnect"]');
    expect(refresh.find('.i-lucide-refresh-cw').exists()).toBe(true);
    expect(refresh.attributes('disabled')).toBeUndefined();
    expect(refresh.attributes('aria-label')).toBe(
      'PHONE_WIDGET.REFRESH_CONNECTION'
    );
    expect(refresh.text()).toBe('');
    await wrapper
      .get('[data-testid="phone-widget-reconnect"]')
      .trigger('click');
    expect(webphoneClient.initializeDevice).toHaveBeenCalledWith(43, {
      native: true,
      provider: 'sipuni',
      sipProfileId: 83,
      sessionKey: 'sip_profile:83',
    });
  });

  it('disables refresh while registering', async () => {
    webphoneClient.sessions['sip_profile:83'] = sipSession({
      registered: false,
    });
    let finishRegistration;
    webphoneClient.initializeDevice.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          finishRegistration = resolve;
        })
    );
    const wrapper = mountComponent();
    await flushPromises();

    await wrapper
      .get('[data-testid="phone-widget-reconnect"]')
      .trigger('click');
    const refresh = wrapper.get('[data-testid="phone-widget-reconnect"]');
    expect(refresh.attributes('disabled')).toBeDefined();
    expect(refresh.attributes('aria-label')).toBe(
      'SIDEBAR.SIP_TELEPHONY.STATUS.CONNECTING'
    );
    expect(wrapper.get('[role="status"] span').classes()).toContain(
      'bg-n-amber-9'
    );
    refresh.element.click();
    expect(webphoneClient.initializeDevice).toHaveBeenCalledOnce();
    finishRegistration();
    await flushPromises();
  });

  it('shows the translated other-tab state and disables refresh', async () => {
    webphoneClient.sessions['sip_profile:83'] = sipSession({
      registered: false,
      callingSupported: false,
      reason: 'sip_profile_registration_lease_owned_by_another_tab',
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.get('[role="status"]').attributes('aria-label')).toContain(
      'ACTIVE_IN_ANOTHER_TAB'
    );
    const refresh = wrapper.get('[data-testid="phone-widget-reconnect"]');
    expect(refresh.attributes('disabled')).toBeDefined();
    expect(refresh.attributes('aria-label')).toBe('PHONE_WIDGET.OTHER_TAB');
    await wrapper.get('[data-testid="phone-widget-expand"]').trigger('click');
    expect(refresh.attributes('disabled')).toBeDefined();
    refresh.element.click();
    expect(webphoneClient.initializeDevice).not.toHaveBeenCalled();
  });

  it('shows only digits and separate plus and delete keys in the keypad', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    await wrapper.get('[data-testid="phone-widget-expand"]').trigger('click');

    const keypad = wrapper.get('[data-testid="phone-widget-expanded"]');
    const digits = keypad.findAll('button[data-testid^="phone-key-"]');
    expect(digits.map(button => button.text())).toEqual([
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '0',
    ]);
    expect(keypad.text()).not.toMatch(/[A-Z*#]/);
    const plus = keypad.get('[data-testid="phone-widget-plus"]');
    expect(plus.text()).toBe('+');
    expect(plus.classes()).toContain('outline-n-strong');
    expect(
      keypad.get('[data-testid="phone-widget-delete"]').attributes('aria-label')
    ).toBe('PHONE_WIDGET.DELETE_DIGIT');

    const input = wrapper.get('input#phone-widget-number');
    await plus.trigger('click');
    await plus.trigger('click');
    expect(input.element.value).toBe('+');
    await keypad.get('[data-testid="phone-key-0"]').trigger('click');
    expect(input.element.value).toBe('+0');
    await keypad.get('[data-testid="phone-widget-delete"]').trigger('click');
    expect(input.element.value).toBe('+');
  });

  it('keeps number entry available when minimized and supports mouse dialing with a plus', async () => {
    const wrapper = mountComponent();
    await flushPromises();
    const input = wrapper.get('input#phone-widget-number');
    expect(input.classes()).toContain('reset-base');
    await input.setValue('77712345678');
    expect(wrapper.get('[data-testid="phone-widget-call"]').text()).toContain(
      '77712345678'
    );

    await wrapper.get('[data-testid="phone-widget-expand"]').trigger('click');
    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      true
    );
    expect(wrapper.get('[data-testid="phone-key-1"]').classes()).toContain(
      'outline-n-strong'
    );
    await wrapper.get('[data-testid="phone-widget-plus"]').trigger('click');
    expect(input.element.value).toBe('+77712345678');
    await wrapper.get('[data-testid="phone-key-1"]').trigger('click');
    expect(input.element.value).toBe('+777123456781');
    await wrapper
      .get('[aria-label="PHONE_WIDGET.DELETE_DIGIT"]')
      .trigger('click');
    expect(input.element.value).toBe('+77712345678');
    const numberBeforeMinimize = input.element.value;
    await wrapper.get('[data-testid="phone-widget-expand"]').trigger('click');
    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      false
    );
    expect(wrapper.get('input#phone-widget-number').element.value).toBe(
      numberBeforeMinimize
    );
  });

  it('starts a call with Enter from the design-system input', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const input = wrapper.get('input#phone-widget-number');
    await input.setValue('77712345678');
    await wrapper.get('[data-testid="phone-widget-expand"]').trigger('click');
    await input.trigger('keyup.enter');

    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      false
    );
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

    const select = wrapper.get('select[data-testid="phone-widget-inbox"]');
    expect(select.classes()).toContain('appearance-none');
    expect(select.attributes('aria-label')).toBe('PHONE_WIDGET.LINE');
    expect(wrapper.find('label[for="phone-widget-inbox"]').exists()).toBe(
      false
    );
    await select.setValue('44');
    expect(wrapper.find('[data-testid="phone-widget-line"]').exists()).toBe(
      false
    );
    await wrapper.get('input#phone-widget-number').setValue('77712345678');
    expect(wrapper.get('[data-testid="phone-widget-call"]').text()).toContain(
      '44'
    );
    expect(wrapper.get('[role="status"]').attributes('aria-label')).toContain(
      'ERROR'
    );
    expect(wrapper.get('[role="status"] span').classes()).toContain(
      'bg-n-ruby-9'
    );
    const refresh = wrapper.get('[data-testid="phone-widget-reconnect"]');
    expect(refresh.attributes('aria-label')).toBe(
      'PHONE_WIDGET.REFRESH_CONNECTION'
    );
    expect(refresh.attributes('disabled')).toBeUndefined();
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

  it('does not mark a failed selected phone as active because another call exists', async () => {
    callsState.hasActiveCall = true;
    webphoneClient.sessions['sip_profile:83'] = sipSession({
      registered: false,
      callingSupported: false,
      reason: 'sip_credentials_failed',
    });
    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.get('[role="status"] span').classes()).toContain(
      'bg-n-ruby-9'
    );
    expect(wrapper.get('[role="status"]').attributes('aria-label')).toContain(
      'ERROR'
    );
    const refresh = wrapper.get('[data-testid="phone-widget-reconnect"]');
    expect(refresh.attributes('aria-label')).toBe(
      'PHONE_WIDGET.REFRESH_CONNECTION'
    );
    expect(refresh.attributes('disabled')).toBeUndefined();
  });
});
