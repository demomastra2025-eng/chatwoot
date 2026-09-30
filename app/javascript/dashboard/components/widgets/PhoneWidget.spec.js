import { flushPromises, mount } from '@vue/test-utils';
import { ref } from 'vue';
import { createPinia, setActivePinia } from 'pinia';
import { usePhoneWidgetStore } from 'dashboard/stores/phoneWidget';
import PhoneWidget from './PhoneWidget.vue';

const {
  webphoneClient,
  callsState,
  values,
  settingsState,
  microphoneState,
  alertMock,
  dialMock,
} = await vi.hoisted(async () => {
  const { reactive } = await import('vue');
  const listeners = {};
  return {
    alertMock: vi.fn(),
    dialMock: vi.fn(),
    values: {
      'inboxes/getInboxes': [],
      getCurrentAccountId: 1,
      getCurrentUser: { name: 'Иван Иванов' },
    },
    callsState: reactive({
      activeCall: null,
      hasActiveCall: false,
      hasIncomingCall: false,
      incomingCalls: [],
    }),
    settingsState: { settings: null, update: vi.fn() },
    microphoneState: { available: null, muted: null, toggle: vi.fn() },
    webphoneClient: {
      sessions: {},
      bootstrapIncomingSupport: vi.fn(() => Promise.resolve()),
      initializeDevice: vi.fn(() => Promise.resolve()),
      // Teardown entry points that hiding the phone must never reach.
      destroyDevice: vi.fn(),
      destroyNativeSession: vi.fn(),
      releaseNativeOwnership: vi.fn(),
      suspendNativeSessions: vi.fn(),
      endClientCall: vi.fn(),
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
              dialMock(this.phone, this.inboxId);
              this.$emit('callInitiated');
            },
          },
        },
        // The call list itself is covered by FloatingCallWidget.spec.js and
        // PhoneWidget.calls.spec.js.
        FloatingCallWidget: {
          props: { embedded: Boolean },
          template:
            '<div data-testid="phone-widget-calls-list" :data-embedded="String(embedded)" />',
        },
      },
    },
  });

const TEARDOWN_METHODS = [
  'destroyDevice',
  'destroyNativeSession',
  'releaseNativeOwnership',
  'suspendNativeSessions',
  'endClientCall',
];
const incomingCall = (overrides = {}) => ({
  callSid: 'sipuni:incoming-1',
  callDirection: 'inbound',
  provider: 'sipuni',
  isActive: false,
  ...overrides,
});
const setIncomingCalls = calls => {
  callsState.incomingCalls = calls;
  callsState.hasIncomingCall = calls.length > 0;
};

describe('PhoneWidget', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
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
    callsState.incomingCalls = [];
    callsState.activeCall = null;
    webphoneClient.sessions = { 'sip_profile:83': sipSession() };
    webphoneClient.bootstrapIncomingSupport.mockReset().mockResolvedValue();
    webphoneClient.initializeDevice.mockReset().mockResolvedValue();
    webphoneClient.addEventListener.mockClear();
    webphoneClient.removeEventListener.mockClear();
    TEARDOWN_METHODS.forEach(method => webphoneClient[method].mockClear());
    alertMock.mockReset();
    dialMock.mockReset();
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
    const phoneWidgetStore = usePhoneWidgetStore();
    await wrapper.get('[data-testid="phone-widget-hide"]').trigger('click');
    // Hidden only visually: the phone and its call list stay mounted.
    expect(
      wrapper.get('[data-testid="phone-widget"]').element.style.display
    ).toBe('none');
    expect(phoneWidgetStore.status).toBe('ready');

    webphoneClient.sessions['sip_profile:83'].registered = false;
    webphoneClient.emit('call:sessions-changed');
    await flushPromises();
    // The sidebar button keeps following the line while the phone is hidden.
    expect(phoneWidgetStore.status).toBe('disconnected');
    expect(webphoneClient.bootstrapIncomingSupport).toHaveBeenCalledOnce();
    settingsState.settings.value = {
      ...settingsState.settings.value,
      phone_widget_hidden_accounts: {},
    };
    await flushPromises();
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
    // Same round call button as the call cards.
    const disabledCall = wrapper.get('button[aria-label="PHONE_WIDGET.CALL"]');
    expect(disabledCall.attributes('disabled')).toBeDefined();
    expect(disabledCall.text()).toBe('');
    expect(disabledCall.find('.i-ph-phone-bold').exists()).toBe(true);
    expect(disabledCall.classes()).toContain('bg-n-button-color');
    expect(disabledCall.classes()).toContain('!rounded-full');

    await wrapper.get('input#phone-widget-number').setValue('77712345678');
    const enabledCall = wrapper.get('[data-testid="phone-widget-call"]');
    expect(enabledCall.find('.i-ph-phone-bold').exists()).toBe(true);
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
    expect(microphone.attributes('aria-pressed')).toBe('false');
    expect(microphone.classes()).not.toContain('bg-n-ruby-9');
    microphone.element.click();
    expect(microphoneState.toggle).not.toHaveBeenCalled();
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
      'PHONE_WIDGET.MICROPHONE_MUTED'
    );

    // The ringtone button silences incoming calls: pressed while silent.
    const ringtone = wrapper.get('[data-testid="phone-widget-ringtone"]');
    expect(ringtone.attributes('aria-pressed')).toBe('false');
    expect(ringtone.find('.i-lucide-bell').exists()).toBe(true);
    await ringtone.trigger('click');
    expect(settingsState.update).toHaveBeenCalledWith({
      voice_call_ringtone_enabled: false,
    });
    expect(ringtone.find('.i-lucide-bell-off').exists()).toBe(true);
    expect(ringtone.attributes('aria-pressed')).toBe('true');
    expect(microphoneState.muted.value).toBe(true);
    await ringtone.trigger('click');
    expect(settingsState.update).toHaveBeenLastCalledWith({
      voice_call_ringtone_enabled: true,
    });
  });

  it('opens and closes the keypad with a dial-pad icon button', async () => {
    const wrapper = mountComponent();
    await flushPromises();

    const toggle = wrapper.get('[data-testid="phone-widget-expand"]');
    expect(toggle.find('.i-fluent-dialpad-20-regular').exists()).toBe(true);
    expect(toggle.find('.i-lucide-maximize-2').exists()).toBe(false);
    expect(toggle.attributes('aria-label')).toBe('PHONE_WIDGET.EXPAND');
    expect(toggle.attributes('aria-expanded')).toBe('false');
    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      false
    );

    await toggle.trigger('click');
    expect(toggle.find('.i-fluent-dialpad-20-regular').exists()).toBe(true);
    expect(toggle.find('.i-lucide-minimize-2').exists()).toBe(false);
    expect(toggle.attributes('aria-label')).toBe('PHONE_WIDGET.MINIMIZE');
    expect(toggle.attributes('aria-expanded')).toBe('true');
    // An open keypad is a filled button, not a faint hover shade.
    expect(toggle.classes()).toContain('bg-n-brand-solid');
    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      true
    );

    await toggle.trigger('click');
    expect(toggle.attributes('aria-label')).toBe('PHONE_WIDGET.EXPAND');
    expect(toggle.attributes('aria-expanded')).toBe('false');
    expect(toggle.classes()).not.toContain('bg-n-brand-solid');
    expect(wrapper.find('[data-testid="phone-widget-expanded"]').exists()).toBe(
      false
    );
  });

  describe('pressed state of the on/off buttons', () => {
    it('fills the microphone button red and says the microphone is off while muted', async () => {
      microphoneState.available.value = true;
      callsState.activeCall = { isActive: true, callSid: 'sipuni:call-1' };
      const wrapper = mountComponent();
      await flushPromises();

      const microphone = wrapper.get('[data-testid="phone-widget-microphone"]');
      expect(microphone.attributes('aria-pressed')).toBe('false');
      expect(microphone.classes()).not.toContain('bg-n-ruby-9');
      expect(microphone.attributes('aria-label')).toBe(
        'PHONE_WIDGET.MUTE_MICROPHONE'
      );
      expect(microphone.attributes('title')).toBe(
        'PHONE_WIDGET.MUTE_MICROPHONE'
      );

      microphoneState.muted.value = true;
      await wrapper.vm.$nextTick();

      expect(microphone.attributes('aria-pressed')).toBe('true');
      expect(microphone.classes()).toEqual(
        expect.arrayContaining(['bg-n-ruby-9', 'text-white'])
      );
      expect(microphone.attributes('aria-label')).toBe(
        'PHONE_WIDGET.MICROPHONE_MUTED'
      );
      expect(microphone.attributes('title')).toBe(
        'PHONE_WIDGET.MICROPHONE_MUTED'
      );
      expect(microphone.find('.i-lucide-mic-off').exists()).toBe(true);

      microphoneState.muted.value = false;
      await wrapper.vm.$nextTick();

      expect(microphone.attributes('aria-pressed')).toBe('false');
      expect(microphone.classes()).not.toContain('bg-n-ruby-9');
      expect(microphone.attributes('aria-label')).toBe(
        'PHONE_WIDGET.MUTE_MICROPHONE'
      );
      expect(microphone.find('.i-lucide-mic').exists()).toBe(true);
    });

    it('fills the ringtone button red while incoming calls ring without sound', async () => {
      settingsState.settings.value = { voice_call_ringtone_enabled: false };
      const wrapper = mountComponent();
      await flushPromises();

      const ringtone = wrapper.get('[data-testid="phone-widget-ringtone"]');
      expect(ringtone.attributes('aria-pressed')).toBe('true');
      expect(ringtone.classes()).toEqual(
        expect.arrayContaining(['bg-n-ruby-9', 'text-white'])
      );
      expect(ringtone.attributes('aria-label')).toBe(
        'PHONE_WIDGET.RINGTONE_MUTED'
      );
      expect(ringtone.attributes('title')).toBe('PHONE_WIDGET.RINGTONE_MUTED');
      expect(ringtone.find('.i-lucide-bell-off').exists()).toBe(true);

      await ringtone.trigger('click');

      expect(settingsState.update).toHaveBeenCalledWith({
        voice_call_ringtone_enabled: true,
      });
      expect(ringtone.attributes('aria-pressed')).toBe('false');
      expect(ringtone.classes()).not.toContain('bg-n-ruby-9');
      expect(ringtone.attributes('aria-label')).toBe(
        'PHONE_WIDGET.DISABLE_RINGTONE'
      );
      expect(ringtone.attributes('title')).toBe(
        'PHONE_WIDGET.DISABLE_RINGTONE'
      );
      expect(ringtone.find('.i-lucide-bell').exists()).toBe(true);
    });
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
      claimOwnership: true,
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
      claimOwnership: true,
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

  describe('when another tab of this browser owns the phone', () => {
    const mirroredSession = (overrides = {}) =>
      sipSession({
        mirrored: true,
        registered: true,
        reason: 'webphone_active_in_owner_tab',
        ...overrides,
      });

    it('shows a green ready state and offers to move the phone here', async () => {
      webphoneClient.sessions['sip_profile:83'] = mirroredSession();
      const wrapper = mountComponent();
      await flushPromises();

      const status = wrapper.get('[role="status"]');
      expect(status.attributes('aria-label')).toBe(
        'Иван Иванов · SIDEBAR.SIP_TELEPHONY.STATUS.READY_IN_OWNER_TAB'
      );
      expect(status.find('span').classes()).toContain('bg-n-teal-9');
      const action = wrapper.get('[data-testid="phone-widget-reconnect"]');
      expect(action.attributes('disabled')).toBeUndefined();
      expect(action.attributes('aria-label')).toBe('PHONE_WIDGET.MOVE_HERE');
      expect(action.attributes('title')).toBe('PHONE_WIDGET.MOVE_HERE');
      expect(action.find('.i-lucide-monitor-down').exists()).toBe(true);
      expect(action.find('.i-lucide-refresh-cw').exists()).toBe(false);
      expect(action.text()).toBe('');

      await wrapper.get('[data-testid="phone-widget-hide"]').trigger('click');
      // Hidden only visually: the phone and its call list stay mounted.
      expect(
        wrapper.get('[data-testid="phone-widget"]').element.style.display
      ).toBe('none');
      expect(usePhoneWidgetStore().status).toBe('ownerTab');
    });

    it('claims the phone for this tab from the status action', async () => {
      webphoneClient.sessions['sip_profile:83'] = mirroredSession();
      let finishClaim;
      webphoneClient.initializeDevice.mockImplementationOnce(
        () =>
          new Promise(resolve => {
            finishClaim = resolve;
          })
      );
      const wrapper = mountComponent();
      await flushPromises();

      await wrapper
        .get('[data-testid="phone-widget-reconnect"]')
        .trigger('click');
      expect(webphoneClient.initializeDevice).toHaveBeenCalledWith(43, {
        native: true,
        provider: 'sipuni',
        sipProfileId: 83,
        sessionKey: 'sip_profile:83',
        claimOwnership: true,
      });
      const action = wrapper.get('[data-testid="phone-widget-reconnect"]');
      expect(action.attributes('disabled')).toBeDefined();
      expect(wrapper.get('[role="status"] span').classes()).toContain(
        'bg-n-amber-9'
      );

      webphoneClient.sessions['sip_profile:83'] = sipSession();
      finishClaim(webphoneClient.sessions['sip_profile:83']);
      await flushPromises();
      expect(wrapper.get('[role="status"]').attributes('aria-label')).toBe(
        'Иван Иванов · SIDEBAR.SIP_TELEPHONY.STATUS.READY'
      );
      expect(action.attributes('disabled')).toBeDefined();
      expect(action.find('.i-lucide-refresh-cw').exists()).toBe(true);
      expect(alertMock).not.toHaveBeenCalled();
    });

    it('explains when the owner tab keeps the phone for a call in progress', async () => {
      webphoneClient.sessions['sip_profile:83'] = mirroredSession();
      webphoneClient.initializeDevice.mockRejectedValueOnce(
        Object.assign(new Error('webphone_owner_tab_busy'), {
          reason: 'webphone_owner_tab_busy',
        })
      );
      const wrapper = mountComponent();
      await flushPromises();

      await wrapper
        .get('[data-testid="phone-widget-reconnect"]')
        .trigger('click');
      await flushPromises();

      expect(alertMock).toHaveBeenCalledWith('PHONE_WIDGET.OWNER_TAB_BUSY');
      expect(wrapper.get('[role="status"]').attributes('aria-label')).toContain(
        'READY_IN_OWNER_TAB'
      );
      expect(
        wrapper
          .get('[data-testid="phone-widget-reconnect"]')
          .attributes('disabled')
      ).toBeUndefined();
    });

    it('moves the phone here when the owner tab lost its registration', async () => {
      webphoneClient.sessions['sip_profile:83'] = mirroredSession({
        registered: false,
        reason: 'sip_unregistered',
      });
      const wrapper = mountComponent();
      await flushPromises();

      expect(wrapper.get('[role="status"]').attributes('aria-label')).toContain(
        'DISCONNECTED'
      );
      const action = wrapper.get('[data-testid="phone-widget-reconnect"]');
      expect(action.attributes('aria-label')).toBe('PHONE_WIDGET.MOVE_HERE');
      expect(action.find('.i-lucide-monitor-down').exists()).toBe(true);
      await action.trigger('click');
      expect(webphoneClient.initializeDevice).toHaveBeenCalledWith(
        43,
        expect.objectContaining({ claimOwnership: true })
      );
    });

    it('keeps the phone on screen as connecting while it moves between tabs', async () => {
      webphoneClient.sessions['sip_profile:83'] = mirroredSession();
      const wrapper = mountComponent();
      await flushPromises();
      vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] });

      try {
        delete webphoneClient.sessions['sip_profile:83'];
        webphoneClient.emit('call:sessions-changed');
        await wrapper.vm.$nextTick();

        expect(wrapper.find('[data-testid="phone-widget"]').exists()).toBe(
          true
        );
        expect(
          wrapper.get('[role="status"]').attributes('aria-label')
        ).toContain('CONNECTING');
        expect(
          wrapper
            .get('[data-testid="phone-widget-reconnect"]')
            .attributes('disabled')
        ).toBeDefined();

        webphoneClient.sessions['sip_profile:83'] = sipSession();
        webphoneClient.emit('call:sessions-changed');
        await wrapper.vm.$nextTick();
        expect(wrapper.get('[role="status"]').attributes('aria-label')).toBe(
          'Иван Иванов · SIDEBAR.SIP_TELEPHONY.STATUS.READY'
        );

        delete webphoneClient.sessions['sip_profile:83'];
        webphoneClient.emit('call:sessions-changed');
        await wrapper.vm.$nextTick();
        vi.advanceTimersByTime(14_999);
        await wrapper.vm.$nextTick();
        expect(wrapper.find('[data-testid="phone-widget"]').exists()).toBe(
          true
        );

        vi.advanceTimersByTime(1);
        await wrapper.vm.$nextTick();
        // The line is gone for good: the phone leaves the screen but stays
        // mounted, so its call cards keep listening for incoming INVITEs.
        const phone = wrapper.find('[data-testid="phone-widget"]');
        expect(phone.exists()).toBe(true);
        expect(phone.isVisible()).toBe(false);
      } finally {
        vi.useRealTimers();
      }
    });
  });

  describe('dialing a copied number', () => {
    const paste = async (wrapper, text) => {
      const input = wrapper.get('input#phone-widget-number');
      const event = new Event('paste', { bubbles: true, cancelable: true });
      Object.defineProperty(event, 'clipboardData', {
        value: { getData: type => (type === 'text' ? text : '') },
      });
      input.element.dispatchEvent(event);
      await wrapper.vm.$nextTick();
      return event;
    };

    it.each([
      '8 (701) 123-45-67',
      '+7 701 123 45 67',
      '7-701-123-45-67',
      '87011234567\n',
      '8 701 123 45 67 Айгерим\nперезвонить после 15:00',
    ])('replaces the field with E.164 when pasting %j', async text => {
      const wrapper = mountComponent();
      await flushPromises();

      const event = await paste(wrapper, text);

      expect(event.defaultPrevented).toBe(true);
      expect(wrapper.get('input#phone-widget-number').element.value).toBe(
        '+77011234567'
      );
      expect(wrapper.get('[data-testid="phone-widget-call"]').text()).toContain(
        '+77011234567'
      );
    });

    it('leaves pasted text without a complete number to the browser', async () => {
      const wrapper = mountComponent();
      await flushPromises();

      const event = await paste(wrapper, '+7 701');

      expect(event.defaultPrevented).toBe(false);
      expect(wrapper.get('input#phone-widget-number').element.value).toBe('');
      expect(wrapper.find('[data-testid="phone-widget-call"]').exists()).toBe(
        false
      );
    });

    it('calls the pasted number immediately on Enter', async () => {
      const wrapper = mountComponent();
      await flushPromises();

      await paste(wrapper, 'Телефон: 8 (701) 123-45-67');
      await wrapper.get('input#phone-widget-number').trigger('keyup.enter');

      expect(dialMock).toHaveBeenCalledOnce();
      expect(dialMock).toHaveBeenCalledWith('+77011234567', 43);
    });

    it('dials a typed number in a local format as E.164', async () => {
      const wrapper = mountComponent();
      await flushPromises();
      const input = wrapper.get('input#phone-widget-number');

      await input.setValue('8 (701) 123-45-67');
      expect(input.element.value).toBe('8 (701) 123-45-67');
      expect(wrapper.get('[data-testid="phone-widget-call"]').text()).toContain(
        '+77011234567'
      );
      await input.trigger('keyup.enter');
      expect(dialMock).toHaveBeenCalledWith('+77011234567', 43);
      dialMock.mockClear();

      await input.setValue('+7 701');
      expect(wrapper.find('[data-testid="phone-widget-call"]').exists()).toBe(
        false
      );
      await input.trigger('keyup.enter');
      expect(dialMock).not.toHaveBeenCalled();
    });
  });

  describe('one phone for dialing and calls', () => {
    const widget = wrapper => wrapper.get('[data-testid="phone-widget"]');
    const dialerShown = wrapper =>
      wrapper.get('[data-testid="phone-widget-dialer"]').element.style
        .display !== 'none';
    const keypadToggleShown = wrapper =>
      wrapper.find('[data-testid="phone-widget-expand"]').exists();
    const activeCall = () =>
      incomingCall({ callSid: 'sipuni:active-1', isActive: true });

    beforeEach(() => {
      values.getCurrentUser = { id: 1, name: 'Иван Иванов' };
    });

    it('shows the call list inside the phone panel, not in a second window', async () => {
      const wrapper = mountComponent();
      await flushPromises();

      const panel = wrapper.get('[data-testid="phone-widget-panel"]');
      const calls = panel.get('[data-testid="phone-widget-calls-list"]');
      expect(calls.attributes('data-embedded')).toBe('true');
      expect(
        wrapper.findAll('[data-testid="phone-widget-calls-list"]')
      ).toHaveLength(1);
    });

    it('idle: shows the dialer and the keypad toggle', async () => {
      const wrapper = mountComponent();
      await flushPromises();

      expect(widget(wrapper).attributes('data-state')).toBe('idle');
      expect(dialerShown(wrapper)).toBe(true);
      expect(keypadToggleShown(wrapper)).toBe(true);
    });

    it('incoming: the ringing call replaces the dialer in the same phone', async () => {
      const wrapper = mountComponent();
      await flushPromises();

      setIncomingCalls([incomingCall()]);
      await flushPromises();

      expect(widget(wrapper).attributes('data-state')).toBe('incoming');
      expect(dialerShown(wrapper)).toBe(false);
      expect(keypadToggleShown(wrapper)).toBe(false);
      expect(
        wrapper
          .get('[data-testid="phone-widget-panel"]')
          .find('[data-testid="phone-widget-calls-list"]')
          .exists()
      ).toBe(true);
    });

    it('dialing: keeps the dialer while the call is prepared, then shows the call', async () => {
      const wrapper = mountComponent();
      await flushPromises();
      const phoneWidgetStore = usePhoneWidgetStore();

      phoneWidgetStore.beginOutboundCall();
      await flushPromises();
      expect(widget(wrapper).attributes('data-state')).toBe('dialing');
      // The call button stays mounted until the call exists.
      expect(dialerShown(wrapper)).toBe(true);

      setIncomingCalls([
        incomingCall({ callSid: 'sipuni:out-1', callDirection: 'outbound' }),
      ]);
      phoneWidgetStore.finishOutboundCall();
      await flushPromises();
      expect(widget(wrapper).attributes('data-state')).toBe('dialing');
      expect(dialerShown(wrapper)).toBe(false);
    });

    it('active: shows the connected call with the in-call status, then returns to the dialer when it ends', async () => {
      const wrapper = mountComponent();
      await flushPromises();
      await wrapper.get('input#phone-widget-number').setValue('77712345678');

      setIncomingCalls([]);
      callsState.hasActiveCall = true;
      callsState.activeCall = activeCall();
      await flushPromises();
      expect(widget(wrapper).attributes('data-state')).toBe('active');
      expect(dialerShown(wrapper)).toBe(false);
      expect(wrapper.get('[role="status"]').attributes('aria-label')).toContain(
        'PHONE_WIDGET.IN_CALL'
      );

      // Ended: the call leaves the calls store.
      callsState.hasActiveCall = false;
      callsState.activeCall = null;
      await flushPromises();
      expect(widget(wrapper).attributes('data-state')).toBe('idle');
      expect(dialerShown(wrapper)).toBe(true);
      expect(keypadToggleShown(wrapper)).toBe(true);
      // The number stays for a quick redial.
      expect(wrapper.get('input#phone-widget-number').element.value).toBe(
        '77712345678'
      );
    });

    it("keeps the dialer for info-only cards of a colleague's or the AI agent's calls", async () => {
      const wrapper = mountComponent();
      await flushPromises();

      setIncomingCalls([
        incomingCall({
          callSid: 'sipuni:other-1',
          status: 'in_progress',
          operatorClaim: { user_id: 99 },
          browserJoinSupported: false,
          browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
        }),
        incomingCall({
          callSid: 'sipuni:ai-1',
          status: 'in_progress',
          serverManagedVoiceCall: true,
          browserJoinSupported: false,
          browserJoinUnsupportedReason: 'AI_AGENT_HANDLING',
        }),
      ]);
      await flushPromises();

      expect(widget(wrapper).attributes('data-state')).toBe('idle');
      expect(dialerShown(wrapper)).toBe(true);
    });
  });

  describe('moving the phone', () => {
    const POSITION_KEY = 'onelink:phone-widget-position';
    const widgetBox = { left: 0, top: 0, width: 336, height: 300 };
    let resizeCallbacks = [];
    const originalInnerWidth = window.innerWidth;
    const originalInnerHeight = window.innerHeight;
    const originalResizeObserver = window.ResizeObserver;

    const setWindowSize = (width, height) => {
      window.innerWidth = width;
      window.innerHeight = height;
    };
    const widget = wrapper => wrapper.get('[data-testid="phone-widget"]');
    const placeOf = wrapper => ({
      left: widget(wrapper).element.style.left,
      top: widget(wrapper).element.style.top,
    });
    const dragHandle = wrapper =>
      wrapper.get('[data-testid="phone-widget-drag-handle"]');
    const pointer = (type, clientX, clientY) =>
      window.dispatchEvent(new MouseEvent(type, { clientX, clientY }));
    // A real pointerdown (button 0 by default) that bubbles to the header.
    const press = async (element, clientX, clientY, init = {}) => {
      const PointerEventClass = window.PointerEvent || window.MouseEvent;
      element.dispatchEvent(
        new PointerEventClass('pointerdown', {
          bubbles: true,
          cancelable: true,
          clientX,
          clientY,
          ...init,
        })
      );
      await flushPromises();
    };
    const savedPlace = () =>
      JSON.parse(window.localStorage.getItem(POSITION_KEY) || 'null');
    let spies = [];

    beforeEach(() => {
      window.localStorage.clear();
      setWindowSize(1280, 800);
      // The default place: top-16 and right-4 of a 1280px window.
      Object.assign(widgetBox, { left: 928, top: 64, width: 336, height: 300 });
      spies = [
        vi
          .spyOn(Element.prototype, 'getBoundingClientRect')
          .mockImplementation(function boundingRect() {
            if (this.dataset?.testid !== 'phone-widget') {
              return { left: 0, top: 0, width: 0, height: 0 };
            }
            return { ...widgetBox };
          }),
      ];
      resizeCallbacks = [];
      window.ResizeObserver = function ResizeObserverStub(callback) {
        resizeCallbacks.push(callback);
        return { observe: () => {}, disconnect: () => {} };
      };
    });

    afterEach(() => {
      spies.forEach(spy => spy.mockRestore());
      window.localStorage.clear();
      setWindowSize(originalInnerWidth, originalInnerHeight);
      window.ResizeObserver = originalResizeObserver;
    });

    it('opens at its default place until it is moved', async () => {
      const wrapper = mountComponent();
      await flushPromises();

      expect(widget(wrapper).classes()).toContain('top-16');
      expect(placeOf(wrapper)).toEqual({ left: '', top: '' });
    });

    it('drags by the header, stays inside the window and remembers the place', async () => {
      const wrapper = mountComponent();
      await flushPromises();

      await press(dragHandle(wrapper).element, 1000, 80);
      pointer('pointermove', 700, 300);
      await flushPromises();
      expect(placeOf(wrapper)).toEqual({ left: '628px', top: '284px' });
      expect(widget(wrapper).classes()).not.toContain('top-16');

      // Far past the bottom-right corner: clamped to the window.
      pointer('pointermove', 5000, 5000);
      await flushPromises();
      expect(placeOf(wrapper)).toEqual({ left: '936px', top: '492px' });
      expect(savedPlace()).toBeNull();

      pointer('pointerup', 5000, 5000);
      await flushPromises();
      expect(savedPlace()).toEqual({ left: 936, top: 492 });

      // Moving the pointer after the drag ended does nothing.
      pointer('pointermove', 10, 10);
      await flushPromises();
      expect(placeOf(wrapper)).toEqual({ left: '936px', top: '492px' });

      // Past the top-left corner (touch drag reports the same pointer events).
      widgetBox.left = 936;
      widgetBox.top = 492;
      await press(dragHandle(wrapper).element, 950, 500, {
        pointerType: 'touch',
      });
      pointer('pointermove', -800, -800);
      pointer('pointercancel', -800, -800);
      await flushPromises();
      expect(placeOf(wrapper)).toEqual({ left: '8px', top: '8px' });
      expect(savedPlace()).toEqual({ left: 8, top: 8 });
    });

    it('does not start a drag from the header buttons or a secondary button', async () => {
      const wrapper = mountComponent();
      await flushPromises();

      await press(
        wrapper.get('[data-testid="phone-widget-ringtone"]').element,
        1100,
        80
      );
      pointer('pointermove', 200, 200);
      pointer('pointerup', 200, 200);
      await press(dragHandle(wrapper).element, 1000, 80, { button: 2 });
      pointer('pointermove', 200, 200);
      pointer('pointerup', 200, 200);
      await flushPromises();

      expect(placeOf(wrapper)).toEqual({ left: '', top: '' });
      expect(savedPlace()).toBeNull();
    });

    it('restores the remembered place and pulls it into a smaller window', async () => {
      window.localStorage.setItem(
        POSITION_KEY,
        JSON.stringify({ left: 2000, top: 2000 })
      );
      setWindowSize(1024, 700);

      const wrapper = mountComponent();
      await flushPromises();

      expect(placeOf(wrapper)).toEqual({ left: '680px', top: '392px' });
    });

    it('stays inside the window when the window shrinks and when the phone grows', async () => {
      window.localStorage.setItem(
        POSITION_KEY,
        JSON.stringify({ left: 900, top: 450 })
      );
      const wrapper = mountComponent();
      await flushPromises();
      expect(placeOf(wrapper)).toEqual({ left: '900px', top: '450px' });

      setWindowSize(1000, 600);
      window.dispatchEvent(new Event('resize'));
      await flushPromises();
      expect(placeOf(wrapper)).toEqual({ left: '656px', top: '292px' });

      // A call card makes the phone taller (ResizeObserver in the browser).
      widgetBox.height = 500;
      resizeCallbacks.forEach(callback => callback([]));
      await flushPromises();
      expect(placeOf(wrapper)).toEqual({ left: '656px', top: '92px' });

      // The same happens when the keypad opens, without a ResizeObserver.
      widgetBox.height = 560;
      await wrapper.get('[data-testid="phone-widget-expand"]').trigger('click');
      await flushPromises();
      expect(placeOf(wrapper)).toEqual({ left: '656px', top: '32px' });
      // Clamping for a small window does not overwrite the chosen place.
      expect(savedPlace()).toEqual({ left: 900, top: 450 });
    });

    it('opens at the default place when the browser storage is blocked', async () => {
      spies.push(
        vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
          throw new Error('SecurityError');
        }),
        vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
          throw new Error('SecurityError');
        })
      );

      const wrapper = mountComponent();
      await flushPromises();
      expect(placeOf(wrapper)).toEqual({ left: '', top: '' });

      await press(dragHandle(wrapper).element, 1000, 80);
      pointer('pointermove', 900, 100);
      pointer('pointerup', 900, 100);
      await flushPromises();
      expect(placeOf(wrapper)).toEqual({ left: '828px', top: '84px' });
    });
  });

  describe('showing and hiding the phone', () => {
    const hiddenIn = (...accountIds) => ({
      phone_widget_hidden_accounts: Object.fromEntries(
        accountIds.map(id => [id, true])
      ),
    });
    // Hiding keeps the phone mounted (so SIP INVITEs are still reported) and
    // only takes it off screen.
    const widgetShown = wrapper => {
      const phone = wrapper.find('[data-testid="phone-widget"]');
      return phone.exists() && phone.element.style.display !== 'none';
    };

    it('hidden does not unregister SIP: sessions stay registered and keep updating', async () => {
      const wrapper = mountComponent();
      await flushPromises();
      const phoneWidgetStore = usePhoneWidgetStore();
      expect(phoneWidgetStore.available).toBe(true);
      expect(phoneWidgetStore.status).toBe('ready');

      await wrapper.get('[data-testid="phone-widget-hide"]').trigger('click');

      expect(settingsState.update).toHaveBeenCalledWith({
        phone_widget_hidden_accounts: { 1: true },
      });
      // Hidden only visually: the phone and its call list stay mounted.
      expect(
        wrapper.get('[data-testid="phone-widget"]').element.style.display
      ).toBe('none');
      TEARDOWN_METHODS.forEach(method => {
        expect(webphoneClient[method]).not.toHaveBeenCalled();
      });
      expect(webphoneClient.removeEventListener).not.toHaveBeenCalled();
      expect(webphoneClient.initializeDevice).not.toHaveBeenCalled();
      expect(webphoneClient.bootstrapIncomingSupport).toHaveBeenCalledOnce();
      expect(phoneWidgetStore.available).toBe(true);

      webphoneClient.sessions['sip_profile:83'] = sipSession({
        registered: false,
        callingSupported: false,
        reason: 'sip_credentials_failed',
      });
      webphoneClient.emit('call:sessions-changed');
      await flushPromises();
      expect(phoneWidgetStore.status).toBe('error');
    });

    it('remembers the hidden phone per account', async () => {
      settingsState.settings.value = hiddenIn(2);
      const wrapper = mountComponent();
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(true);

      settingsState.settings.value = hiddenIn(1);
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(false);
      expect(usePhoneWidgetStore().available).toBe(true);
      wrapper.unmount();

      values.getCurrentAccountId = 2;
      const otherAccount = mountComponent();
      await flushPromises();
      expect(widgetShown(otherAccount)).toBe(true);
    });

    it('incoming call while hidden pops the widget and hides it again after the call', async () => {
      settingsState.settings.value = hiddenIn(1);
      const wrapper = mountComponent();
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(false);

      setIncomingCalls([incomingCall()]);
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(true);

      setIncomingCalls([]);
      callsState.hasActiveCall = true;
      callsState.activeCall = incomingCall({ isActive: true });
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(true);
      expect(wrapper.get('[role="status"]').attributes('aria-label')).toContain(
        'PHONE_WIDGET.IN_CALL'
      );

      callsState.hasActiveCall = false;
      callsState.activeCall = null;
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(false);
      // The saved choice is untouched by the automatic pop-up.
      expect(settingsState.update).not.toHaveBeenCalled();
    });

    it('pops the widget while an outbound call is started and until it ends', async () => {
      settingsState.settings.value = hiddenIn(1);
      const wrapper = mountComponent();
      await flushPromises();
      const phoneWidgetStore = usePhoneWidgetStore();

      phoneWidgetStore.beginOutboundCall();
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(true);

      // VoiceCallButton adds the created call before it finishes preparing.
      setIncomingCalls([
        incomingCall({ callSid: 'sipuni:out-1', callDirection: 'outbound' }),
      ]);
      phoneWidgetStore.finishOutboundCall();
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(true);

      setIncomingCalls([]);
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(false);
    });

    it('keeps a call hidden once the employee hides it, until another call rings', async () => {
      const wrapper = mountComponent();
      await flushPromises();
      setIncomingCalls([incomingCall()]);
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(true);

      await wrapper.get('[data-testid="phone-widget-hide"]').trigger('click');
      expect(settingsState.update).toHaveBeenCalledWith({
        phone_widget_hidden_accounts: { 1: true },
      });
      expect(widgetShown(wrapper)).toBe(false);

      setIncomingCalls([incomingCall()]);
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(false);

      setIncomingCalls([
        incomingCall(),
        incomingCall({ callSid: 'sipuni:incoming-2' }),
      ]);
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(true);

      setIncomingCalls([]);
      await flushPromises();
      expect(widgetShown(wrapper)).toBe(false);
      expect(usePhoneWidgetStore().callDismissed).toBe(false);
    });

    describe('when a colleague takes a call', () => {
      // The info card of an inbox that shows calls handled by other operators.
      const colleagueCall = (callSid = 'sipuni:other-1') =>
        incomingCall({
          callSid,
          status: 'in_progress',
          operatorClaim: { user_id: 99 },
          browserJoinSupported: false,
          browserJoinUnsupportedReason: 'CALL_ALREADY_CLAIMED',
        });

      beforeEach(() => {
        values.getCurrentUser = { id: 1, name: 'Иван Иванов' };
      });

      it('does not pop a hidden phone', async () => {
        settingsState.settings.value = hiddenIn(1);
        const wrapper = mountComponent();
        await flushPromises();

        setIncomingCalls([colleagueCall()]);
        await flushPromises();
        expect(widgetShown(wrapper)).toBe(false);

        setIncomingCalls([colleagueCall(), incomingCall()]);
        await flushPromises();
        expect(widgetShown(wrapper)).toBe(true);
      });

      it('keeps the phone hidden for the dismissed call', async () => {
        const wrapper = mountComponent();
        await flushPromises();
        setIncomingCalls([incomingCall()]);
        await flushPromises();
        await wrapper.get('[data-testid="phone-widget-hide"]').trigger('click');
        expect(widgetShown(wrapper)).toBe(false);

        setIncomingCalls([incomingCall(), colleagueCall('sipuni:other-2')]);
        await flushPromises();

        expect(widgetShown(wrapper)).toBe(false);
        expect(usePhoneWidgetStore().callDismissed).toBe(true);
      });
    });

    describe('info-only cards of calls this employee cannot join', () => {
      const aiAgentCall = (callSid = 'sipuni:ai-1') =>
        incomingCall({
          callSid,
          status: 'in_progress',
          serverManagedVoiceCall: true,
          browserJoinSupported: false,
          browserJoinUnsupportedReason: 'AI_AGENT_HANDLING',
        });
      const unclaimedInProgressCall = (callSid = 'sipuni:unclaimed-1') =>
        incomingCall({
          callSid,
          status: 'in_progress',
          browserJoinSupported: false,
          browserJoinUnsupportedReason: 'CALL_IN_PROGRESS',
        });

      beforeEach(() => {
        values.getCurrentUser = { id: 1, name: 'Иван Иванов' };
      });

      it.each([
        ['the AI voice agent handles', aiAgentCall],
        ['nobody here claimed', unclaimedInProgressCall],
      ])('does not pop a hidden phone for a call %s', async (_, infoCall) => {
        settingsState.settings.value = hiddenIn(1);
        const wrapper = mountComponent();
        await flushPromises();

        setIncomingCalls([infoCall()]);
        await flushPromises();
        expect(widgetShown(wrapper)).toBe(false);

        // The employee's own ringing call still pops the phone.
        setIncomingCalls([infoCall(), incomingCall()]);
        await flushPromises();
        expect(widgetShown(wrapper)).toBe(true);
      });

      it.each([
        ['the AI voice agent handles', aiAgentCall],
        ['nobody here claimed', unclaimedInProgressCall],
      ])(
        'does not clear the dismissal of the current call for a call %s',
        async (_, infoCall) => {
          const wrapper = mountComponent();
          await flushPromises();
          setIncomingCalls([incomingCall()]);
          await flushPromises();
          await wrapper
            .get('[data-testid="phone-widget-hide"]')
            .trigger('click');
          expect(widgetShown(wrapper)).toBe(false);

          setIncomingCalls([incomingCall(), infoCall('sipuni:info-2')]);
          await flushPromises();

          expect(widgetShown(wrapper)).toBe(false);
          expect(usePhoneWidgetStore().callDismissed).toBe(true);
        }
      );
    });

    it('does not offer the sidebar button without a browser SIP line', async () => {
      webphoneClient.sessions = {};
      mountComponent();
      await flushPromises();

      expect(usePhoneWidgetStore().available).toBe(false);
    });

    it('withdraws the sidebar button when the widget is unmounted', async () => {
      const wrapper = mountComponent();
      await flushPromises();
      expect(usePhoneWidgetStore().available).toBe(true);

      wrapper.unmount();

      expect(usePhoneWidgetStore().available).toBe(false);
    });
  });
});
